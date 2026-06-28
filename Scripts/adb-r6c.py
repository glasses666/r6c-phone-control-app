#!/usr/bin/env python3
import os
import shlex
import subprocess
import sys
from pathlib import Path


SSH_KEY = os.environ.get(
    "R6C_SSH_KEY",
    str(Path.home() / "Library/Application Support/R6CPhoneControl/r6c-scrcpy/ssh_ed25519"),
)
SSH_HOST = os.environ.get("R6C_SSH_HOST", "")
SSH_PORT = os.environ.get("R6C_SSH_PORT", "22")
REMOTE_ADB = os.environ.get("R6C_REMOTE_ADB", "/usr/bin/adb")
REMOTE_KEYS = os.environ.get("R6C_REMOTE_ADB_VENDOR_KEYS", "/root/.android")


def base_ssh():
    if not SSH_HOST:
        print("ERROR set R6C_SSH_HOST or add a remote in the app", file=sys.stderr)
        sys.exit(2)
    return [
        "ssh",
        "-i",
        SSH_KEY,
        "-p",
        SSH_PORT,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        SSH_HOST,
    ]


def base_scp():
    if not SSH_HOST:
        print("ERROR set R6C_SSH_HOST or add a remote in the app", file=sys.stderr)
        sys.exit(2)
    return [
        "scp",
        "-i",
        SSH_KEY,
        "-P",
        SSH_PORT,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
    ]


def remote_shell(argv):
    remote = "ADB_VENDOR_KEYS={} {} {}".format(
        shlex.quote(REMOTE_KEYS),
        shlex.quote(REMOTE_ADB),
        " ".join(shlex.quote(a) for a in argv),
    )
    return subprocess.call(base_ssh() + [remote])


def upload(local_path):
    src = Path(local_path)
    remote = f"/tmp/r6c-scrcpy-push-{os.getpid()}-{src.name}"
    rc = subprocess.call(base_scp() + [str(src), f"{SSH_HOST}:{remote}"])
    if rc != 0:
        return rc, remote
    return 0, remote


def main():
    args = sys.argv[1:]
    if not args:
        return remote_shell(args)

    if "push" not in args:
        return remote_shell(args)

    idx = args.index("push")
    prefix = args[:idx]
    rest = args[idx + 1 :]
    flags = []
    while rest and rest[0].startswith("-"):
        flags.append(rest.pop(0))

    if len(rest) < 2:
        return remote_shell(args)

    local_src, remote_dst = rest[0], rest[1]
    rc, remote_tmp = upload(local_src)
    if rc != 0:
        return rc

    try:
        return remote_shell(prefix + ["push"] + flags + [remote_tmp, remote_dst])
    finally:
        subprocess.call(base_ssh() + [f"rm -f {shlex.quote(remote_tmp)}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    raise SystemExit(main())
