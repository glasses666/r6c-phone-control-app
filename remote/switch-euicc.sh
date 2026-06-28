#!/bin/sh
set -eu

ENV_FILE="${R6C_SIM_SWITCH_ENV:-/root/.r6c-sim-switch.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

ADB="${ADB:-/usr/bin/adb}"
export ADB_VENDOR_KEYS="${ADB_VENDOR_KEYS:-/root/.android}"
SERIAL="${R6C_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
PACKAGE="${EASYEUICC_PACKAGE:-im.angry.easyeuicc}"
CLI_AUTHORITY="${EASYEUICC_CLI_AUTHORITY:-$PACKAGE.cli}"
CLI_URI="content://$CLI_AUTHORITY"

usage() {
  cat <<'EOF'
Usage:
  switch-euicc.sh list
  switch-euicc.sh list-json
  switch-euicc.sh status
  switch-euicc.sh switch <profile-or-provider-or-iccid>
  switch-euicc.sh switch-exact <profile-name> [provider]
  switch-euicc.sh switch-iccid <iccid>
  switch-euicc.sh display fast
  switch-euicc.sh display reset

Environment:
  R6C_ANDROID_SERIAL       Optional adb serial; auto-detected when omitted.
  R6C_SIM_SWITCH_ENV       Optional env file path; default /root/.r6c-sim-switch.env.
  EASYEUICC_PACKAGE        Optional EasyEUICC package; default im.angry.easyeuicc.
  EASYEUICC_CLI_AUTHORITY  Optional provider authority; default $EASYEUICC_PACKAGE.cli.

EasyEUICC must include the exported DUMP-protected CLI provider.
This script intentionally does not use UIAutomator, screenshots, OCR, or taps.
EOF
}

need_device() {
  if [ -z "$SERIAL" ]; then
    SERIAL="$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
  fi
  [ -n "$SERIAL" ] || {
    echo "ERROR no adb device in device state" >&2
    exit 1
  }
}

adb_shell() {
  "$ADB" -s "$SERIAL" shell "$@"
}

url_encode() {
  lua - "$1" <<'LUA'
local s = arg[1] or ""
io.write((s:gsub("[^A-Za-z0-9_.~-]", function(c)
  return string.format("%%%02X", string.byte(c))
end)))
LUA
}

content_read() {
  need_device
  uri="$1"
  if out="$(adb_shell content read --uri "$uri" 2>&1)"; then
    case "$out" in
      *"Could not find provider"*|*"Error while accessing provider"*)
        printf '%s\n' "$out" >&2
        cat >&2 <<EOF
ERROR EasyEUICC CLI provider unavailable or failed.
Expected provider: $CLI_AUTHORITY
Expected permission model: exported provider protected by android.permission.DUMP.
EOF
        exit 1
        ;;
    esac
    printf '%s\n' "$out"
    return 0
  fi

  rc="$?"
  printf '%s\n' "$out" >&2
  cat >&2 <<EOF
ERROR EasyEUICC CLI provider unavailable or failed.
Expected provider: $CLI_AUTHORITY
Expected permission model: exported provider protected by android.permission.DUMP.
EOF
  exit "$rc"
}

profiles_text() {
  content_read "$CLI_URI/profiles.txt"
}

profiles_json() {
  content_read "$CLI_URI/profiles.json"
}

switch_target() {
  target="$1"
  content_read "$CLI_URI/switch.json?target=$(url_encode "$target")"
}

switch_exact() {
  name="$1"
  provider="${2:-}"
  content_read "$CLI_URI/switch-exact.json?name=$(url_encode "$name")&provider=$(url_encode "$provider")"
}

switch_iccid() {
  iccid="$1"
  content_read "$CLI_URI/switch-iccid/$(url_encode "$iccid")"
}

display_mode() {
  mode="${1:-}"
  need_device
  case "$mode" in
    fast)
      adb_shell wm size 540x1170
      adb_shell wm density 220
      ;;
    reset|restore)
      adb_shell wm size reset
      adb_shell wm density reset
      ;;
    status|'')
      ;;
    *)
      echo "ERROR unknown display mode: $mode" >&2
      exit 2
      ;;
  esac
  adb_shell wm size
  adb_shell wm density
}

cmd="${1:-}"
case "$cmd" in
  list|status)
    profiles_text
    ;;
  list-json|json)
    profiles_json
    ;;
  switch)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    switch_target "$2"
    ;;
  switch-exact)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    switch_exact "$2" "${3:-}"
    ;;
  switch-iccid)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    switch_iccid "$2"
    ;;
  display)
    display_mode "${2:-status}"
    ;;
  -h|--help|help|'')
    usage
    ;;
  *)
    echo "ERROR unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
