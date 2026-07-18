#!/usr/bin/env python3
"""Forward new SMS messages from a DJI IG830 modem to Bark."""

from __future__ import annotations

import argparse
import csv
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from typing import Iterable
from urllib import parse, request


MESSAGES_ICON = (
    "https://is1-ssl.mzstatic.com/image/thumb/Purple221/v4/0e/08/07/"
    "0e080793-1b66-d9b3-0bbe-8222669abf79/"
    "messages-0-0-1x_U007epad-0-1-0-sRGB-85-220.png/512x512bb.jpg"
)
ALLOWED_ENV_KEYS = {
    "R6C_BARK_URL",
    "R6C_SMS_PROVIDER",
    "R6C_SMS_DELETE_AFTER_PUSH",
    "R6C_SMS_POLL_SECONDS",
}


class SMSMessage:
    def __init__(self, index: int, status: str, sender: str, timestamp: str, body: str):
        self.index = index
        self.status = status
        self.sender = decode_ucs2(sender) or "Unknown sender"
        self.timestamp = timestamp
        self.body = "\n".join(decode_ucs2(line) for line in body.splitlines()).strip()

    @property
    def fingerprint(self) -> str:
        value = f"{self.index}\0{self.sender}\0{self.timestamp}\0{self.body}"
        return hashlib.sha256(value.encode("utf-8")).hexdigest()


def default_state_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/R6C Phone Control/SMS"
    if os.geteuid() == 0:
        return Path("/var/lib/r6c-phone-control/sms")
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "r6c-phone-control/sms"


def default_env_file() -> Path:
    override = os.environ.get("R6C_BARK_ENV_FILE")
    if override:
        return Path(override).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/R6C Phone Control/bark.env"
    return Path("/etc/r6c-phone-control/bark.env")


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in ALLOWED_ENV_KEYS or key in os.environ:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ[key] = value


def resolve_executable(env_key: str, candidates: Iterable[Path], command: str) -> Path:
    configured = os.environ.get(env_key)
    if configured and os.access(configured, os.X_OK):
        return Path(configured)
    for candidate in candidates:
        if os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which(command)
    if found:
        return Path(found)
    raise RuntimeError(f"{command} is not installed")


def resolve_helper() -> Path:
    script_dir = Path(__file__).resolve().parent
    return resolve_executable(
        "DJI_AT_HELPER",
        (
            script_dir / "dji-at-helper",
            script_dir.parent / ".build/dji-at-helper",
            Path("/usr/local/libexec/r6c-phone-control/dji-at-helper"),
        ),
        "dji-at-helper",
    )


def resolve_lpac() -> Path | None:
    script_dir = Path(__file__).resolve().parent
    try:
        return resolve_executable(
            "R6C_LPAC",
            (
                script_dir / "lpac/lpac",
                script_dir.parent / "Vendor/lpac-dji/lpac",
                Path("/usr/local/libexec/r6c-phone-control/lpac"),
            ),
            "lpac",
        )
    except RuntimeError:
        return None


def decode_ucs2(value: str) -> str:
    clean = value.strip()
    if not clean or len(clean) % 4 or not re.fullmatch(r"[0-9A-Fa-f]+", clean):
        return clean
    try:
        decoded = bytes.fromhex(clean).decode("utf-16-be")
    except (UnicodeDecodeError, ValueError):
        return clean
    return decoded if decoded.isprintable() else clean


def parse_cmgl(output: str) -> list[SMSMessage]:
    messages: list[SMSMessage] = []
    header: list[str] | None = None
    body_lines: list[str] = []

    def flush() -> None:
        nonlocal header, body_lines
        if not header:
            return
        try:
            index = int(header[0].strip())
        except (ValueError, IndexError):
            header = None
            body_lines = []
            return
        status = header[1].strip() if len(header) > 1 else ""
        sender = header[2].strip() if len(header) > 2 else ""
        timestamp = next(
            (field.strip() for field in header[3:] if re.match(r"\d{2}/\d{2}/\d{2},", field.strip())),
            "",
        )
        messages.append(SMSMessage(index, status, sender, timestamp, "\n".join(body_lines)))
        header = None
        body_lines = []

    lines = output.replace("\r", "").splitlines()
    for position, raw_line in enumerate(lines):
        line = raw_line.strip()
        if line.startswith("+CMGL:"):
            flush()
            try:
                header = next(csv.reader([line.split(":", 1)[1].strip()]))
            except (csv.Error, StopIteration):
                header = None
            continue
        if header is not None and line == "OK":
            following = next(
                (candidate.strip() for candidate in lines[position + 1 :] if candidate.strip()),
                "",
            )
            if not following or following.startswith("@@END"):
                flush()
                continue
        if header is not None and line.startswith("@@END"):
            flush()
            continue
        if header is not None and line and not line.startswith("AT+CMGL"):
            body_lines.append(line)
    flush()
    return messages


class DJIAT:
    def __init__(self, helper: Path):
        self.helper = helper

    def run(self, command: str, timeout: int = 35) -> str:
        result = subprocess.run(
            [str(self.helper), "raw", command],
            check=False,
            capture_output=True,
            timeout=timeout,
        )
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        if result.returncode != 0 or "TRANSPORT_ERROR:" in output:
            raise RuntimeError(f"AT command failed: {command}")
        return output

    def configure_sms(self) -> None:
        for command in (
            "AT+CMGF=1",
            'AT+CSCS="UCS2"',
            'AT+CPMS="SM","SM","SM"',
            "AT+CNMI=2,1,0,0,0",
        ):
            output = self.run(command)
            if "\nOK" not in output.replace("\r", ""):
                raise RuntimeError(f"Modem rejected: {command}")

    def messages(self) -> list[SMSMessage]:
        return parse_cmgl(self.run('AT+CMGL="ALL"'))

    def delete(self, index: int) -> None:
        output = self.run(f"AT+CMGD={index}")
        if "\nOK" not in output.replace("\r", ""):
            raise RuntimeError(f"Unable to clear SMS slot {index}")


def active_provider() -> str:
    configured = os.environ.get("R6C_SMS_PROVIDER", "").strip()
    if configured:
        return configured
    lpac = resolve_lpac()
    if lpac is None:
        return "eSIM"
    environment = os.environ.copy()
    environment.update({"LPAC_APDU": "dji_usb", "LPAC_HTTP": "curl", "DJI_AT_INTERFACE": "3"})
    for key in ("ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "all_proxy", "https_proxy", "http_proxy"):
        environment.pop(key, None)
    try:
        result = subprocess.run(
            [str(lpac), "profile", "list"],
            cwd=lpac.parent,
            env=environment,
            check=False,
            capture_output=True,
            timeout=35,
        )
        root = json.loads(result.stdout.decode("utf-8"))
        for profile in root.get("payload", {}).get("data", []):
            if str(profile.get("profileState", "")).lower() != "enabled":
                continue
            for key in ("serviceProviderName", "profileNickname", "profileName"):
                if str(profile.get(key, "")).strip():
                    return str(profile[key]).strip()
    except (json.JSONDecodeError, OSError, subprocess.SubprocessError):
        pass
    return "eSIM"


class Bark:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint

    def send(self, sender: str, body: str, provider: str) -> None:
        payload = parse.urlencode(
            {
                "title": f"{sender} · {provider}",
                "body": body or "(empty message)",
                "group": "\u77ed\u4fe1",
                "icon": MESSAGES_ICON,
                "level": "active",
                "isArchive": "1",
            }
        ).encode("utf-8")
        req = request.Request(self.endpoint, data=payload, method="POST")
        with request.urlopen(req, timeout=20) as response:
            result = json.loads(response.read().decode("utf-8"))
        if result.get("code") != 200:
            raise RuntimeError("Bark rejected the push")


class State:
    def __init__(self, directory: Path):
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(directory, 0o700)
        self.directory = directory
        self.seen_path = directory / "seen.json"
        self.archive_path = directory / "archive.jsonl"
        self.lock_file = (directory / "watcher.lock").open("a+", encoding="utf-8")
        fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            self.seen = set(json.loads(self.seen_path.read_text(encoding="utf-8")))
        except (FileNotFoundError, json.JSONDecodeError):
            self.seen: set[str] = set()

    def record(self, message: SMSMessage, provider: str) -> None:
        entry = {
            "receivedAt": int(time.time()),
            "modemTimestamp": message.timestamp,
            "sender": message.sender,
            "body": message.body,
            "provider": provider,
        }
        with self.archive_path.open("a", encoding="utf-8") as archive:
            archive.write(json.dumps(entry, ensure_ascii=False) + "\n")
        os.chmod(self.archive_path, 0o600)
        self.seen.add(message.fingerprint)
        recent = sorted(self.seen)[-2000:]
        self.seen_path.write_text(json.dumps(recent), encoding="utf-8")
        os.chmod(self.seen_path, 0o600)


def delete_after_push() -> bool:
    return os.environ.get("R6C_SMS_DELETE_AFTER_PUSH", "1").lower() not in {"0", "false", "no"}


def scan_once(modem: DJIAT, bark: Bark, state: State) -> int:
    delivered = 0
    for message in modem.messages():
        if message.fingerprint in state.seen:
            if delete_after_push():
                modem.delete(message.index)
            continue
        provider = active_provider()
        bark.send(message.sender, message.body, provider)
        state.record(message, provider)
        if delete_after_push():
            modem.delete(message.index)
        delivered += 1
    return delivered


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--watch", action="store_true", help="poll continuously")
    mode.add_argument("--test-push", action="store_true", help="send a synthetic Bark notification")
    args = parser.parse_args()

    load_env_file(default_env_file())
    endpoint = os.environ.get("R6C_BARK_URL", "").strip()
    while args.watch and not endpoint.startswith("https://"):
        print("Waiting for a secure Bark endpoint.", file=sys.stderr, flush=True)
        time.sleep(60)
        load_env_file(default_env_file())
        endpoint = os.environ.get("R6C_BARK_URL", "").strip()
    if not endpoint.startswith("https://"):
        print("R6C_BARK_URL must be set to an HTTPS Bark endpoint", file=sys.stderr)
        return 2

    bark = Bark(endpoint)
    if args.test_push:
        provider = active_provider()
        bark.send(
            "\u77ed\u4fe1\u6d4b\u8bd5",
            "DJI 4G -> Bark \u901a\u9053\u5df2\u63a5\u901a\uff08\u6a21\u62df\u77ed\u4fe1\uff0c\u672a\u6539\u52a8 SIM\uff09",
            provider,
        )
        print(f"Bark test delivered for {provider}.")
        return 0

    try:
        state = State(Path(os.environ.get("R6C_SMS_STATE_DIR", default_state_dir())))
    except BlockingIOError:
        print("DJI SMS watcher is already running.")
        return 0
    modem = DJIAT(resolve_helper())
    interval = max(2.0, float(os.environ.get("R6C_SMS_POLL_SECONDS", "8")))

    while True:
        try:
            modem.configure_sms()
            delivered = scan_once(modem, bark, state)
            if delivered:
                print(f"Delivered {delivered} SMS message(s).", flush=True)
        except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
            print(f"SMS watcher retrying: {error}", file=sys.stderr, flush=True)
            if not args.watch:
                return 1
        if not args.watch:
            return 0
        time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main())
