#!/bin/sh
set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SCRCPY_DIR="${R6C_SCRCPY_DIR:-$DIR}"
SSH_KEY="${R6C_SSH_KEY:-$SCRCPY_DIR/ssh_ed25519}"
SSH_HOST="${R6C_SSH_HOST:-}"
SSH_PORT="${R6C_SSH_PORT:-22}"
SCRCPY_PORT="${R6C_SCRCPY_PORT:-27183}"
SCRCPY_VERBOSITY="${R6C_SCRCPY_VERBOSITY:-info}"
SCRCPY_WINDOW_TITLE="${R6C_SCRCPY_WINDOW_TITLE:-R6C scrcpy}"
SCRCPY_SERIAL="${R6C_ANDROID_SERIAL:-}"
ADB_WRAPPER="${R6C_ADB_WRAPPER:-$SCRCPY_DIR/adb-r6c.py}"
REMOTE_AUTH_SCRIPT="${R6C_REMOTE_AUTH_SCRIPT:-/root/r6c-scrcpy/authorize-adb-aoa.sh}"

if ! command -v scrcpy >/dev/null 2>&1; then
  echo "scrcpy is not installed" >&2
  exit 1
fi

[ -n "$SSH_HOST" ] || {
  echo "ERROR set R6C_SSH_HOST or add a remote in the app" >&2
  exit 2
}

[ -n "$SCRCPY_SERIAL" ] || {
  echo "ERROR set R6C_ANDROID_SERIAL or select a device in the app" >&2
  exit 2
}

if [ ! -f "$ADB_WRAPPER" ]; then
  echo "missing adb wrapper: $ADB_WRAPPER" >&2
  exit 1
fi

if [ ! -x "$ADB_WRAPPER" ]; then
  chmod +x "$ADB_WRAPPER"
fi

ssh_base() {
  ssh \
    -i "$SSH_KEY" \
    -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    "$@"
}

adb_authorized() {
  "$ADB_WRAPPER" devices -l | grep -q 'device usb:'
}

authorize_adb() {
  echo "r6c adb is not authorized; trying remote AOA-HID authorization..." >&2
  ssh_base "$SSH_HOST" "$REMOTE_AUTH_SCRIPT" >&2
}

if ! adb_authorized; then
  authorize_adb || true
fi

if ! adb_authorized; then
  echo "r6c adb is still not authorized after remote AOA-HID attempt." >&2
  "$ADB_WRAPPER" devices -l >&2 || true
  exit 2
fi

ctl="/tmp/r6c-scrcpy-ssh-ctl"
ssh_base -S "$ctl" -O exit "$SSH_HOST" >/dev/null 2>&1 || true
rm -f "$ctl"

ssh -fN -M -S "$ctl" \
  -i "$SSH_KEY" \
  -p "$SSH_PORT" \
  -o BatchMode=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=2 \
  -L "127.0.0.1:$SCRCPY_PORT:127.0.0.1:$SCRCPY_PORT" \
  "$SSH_HOST"

cleanup() {
  ssh_base -S "$ctl" -O exit "$SSH_HOST" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

set -- \
  -V "$SCRCPY_VERBOSITY" \
  --serial "$SCRCPY_SERIAL" \
  --force-adb-forward \
  --port "$SCRCPY_PORT" \
  --tunnel-host 127.0.0.1 \
  --tunnel-port "$SCRCPY_PORT" \
  --no-audio \
  --max-size 720 \
  --video-bit-rate 2M \
  --max-fps 30 \
  --window-title "$SCRCPY_WINDOW_TITLE"

if [ "${R6C_SCRCPY_BORDERLESS:-0}" = "1" ]; then
  set -- "$@" --window-borderless
fi
if [ "${R6C_SCRCPY_ALWAYS_ON_TOP:-0}" = "1" ]; then
  set -- "$@" --always-on-top
fi
if [ -n "${R6C_SCRCPY_WINDOW_X:-}" ]; then
  set -- "$@" --window-x "$R6C_SCRCPY_WINDOW_X"
fi
if [ -n "${R6C_SCRCPY_WINDOW_Y:-}" ]; then
  set -- "$@" --window-y "$R6C_SCRCPY_WINDOW_Y"
fi
if [ -n "${R6C_SCRCPY_WINDOW_WIDTH:-}" ]; then
  set -- "$@" --window-width "$R6C_SCRCPY_WINDOW_WIDTH"
fi
if [ -n "${R6C_SCRCPY_WINDOW_HEIGHT:-}" ]; then
  set -- "$@" --window-height "$R6C_SCRCPY_WINDOW_HEIGHT"
fi

ADB="$ADB_WRAPPER" scrcpy "$@"
