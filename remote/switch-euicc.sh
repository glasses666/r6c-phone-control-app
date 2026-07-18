#!/bin/sh
set -eu

ENV_FILE="${R6C_SIM_SWITCH_ENV:-/root/.r6c-sim-switch.env}"
REQUESTED_SERIAL="${R6C_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

ADB="${ADB:-/usr/bin/adb}"
export ADB_VENDOR_KEYS="${ADB_VENDOR_KEYS:-/root/.android}"
SERIAL="${REQUESTED_SERIAL:-${R6C_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}}"
PACKAGE="${EASYEUICC_PACKAGE:-im.angry.easyeuicc}"
CLI_AUTHORITY="${EASYEUICC_CLI_AUTHORITY:-$PACKAGE.cli}"
CLI_URI="content://$CLI_AUTHORITY"
DIRECT_CLI_REMOTE_DEX="${EASYEUICC_DIRECT_CLI_REMOTE_DEX:-/root/r6c-sim-switch/euicc-app-process-cli.dex}"
DIRECT_CLI_DEVICE_DEX="${EASYEUICC_DIRECT_CLI_DEVICE_DEX:-/data/local/tmp/euicc-app-process-cli.dex}"
DIRECT_CLI_CLASS="${EASYEUICC_DIRECT_CLI_CLASS:-im.dracoglasser.euicccli.EuiccAppProcessCli}"
DIRECT_CLI_READER="${EASYEUICC_DIRECT_CLI_READER:-SIM1}"
DIRECT_CLI_HTTP_PROXY="${EASYEUICC_HTTP_PROXY:-http://127.0.0.1:3128}"
APP_PROCESS="${EASYEUICC_APP_PROCESS:-/system/bin/app_process}"

usage() {
  cat <<'EOF'
Usage:
  switch-euicc.sh list
  switch-euicc.sh list-json
  switch-euicc.sh status
  switch-euicc.sh switch <profile-or-provider-or-iccid>
  switch-euicc.sh switch-exact <profile-name> [provider]
  switch-euicc.sh switch-iccid <iccid>
  switch-euicc.sh download-parse <LPA-or-url>
  switch-euicc.sh download-dry-run <LPA-or-url>
  switch-euicc.sh download <LPA-or-url> [confirmation-code]
  switch-euicc.sh dns start|status|stop
  switch-euicc.sh display fast
  switch-euicc.sh display reset

Environment:
  R6C_ANDROID_SERIAL       Optional adb serial; auto-detected when omitted.
  R6C_SIM_SWITCH_ENV       Optional env file path; default /root/.r6c-sim-switch.env.
  EASYEUICC_PACKAGE        Optional EasyEUICC package; default im.angry.easyeuicc.
  EASYEUICC_CLI_AUTHORITY  Optional provider authority; default $EASYEUICC_PACKAGE.cli.

EasyEUICC must include the exported DUMP-protected CLI provider.
When the provider is unavailable, this script falls back to a root app_process
CLI that runs under the installed EasyEUICC UID and reuses EasyEUICC's LPAC JNI.
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

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

shell_arg_expr() {
  hexesc="$(lua - "$1" <<'LUA'
local s = arg[1] or ""
io.write((s:gsub(".", function(c)
  return string.format("\\x%02X", string.byte(c))
end)))
LUA
)"
  printf '"$(printf %s)"' "$(shell_quote "$hexesc")"
}

content_read() {
  need_device
  uri="$1"
  if out="$(adb_shell content read --uri "$uri" 2>&1)"; then
    if [ -z "$out" ]; then
      return 10
    fi
    case "$out" in
      *"Could not find provider"*|*"Error while accessing provider"*)
        printf '%s\n' "$out" >&2
        return 10
        ;;
    esac
    printf '%s\n' "$out"
    return 0
  fi

  rc="$?"
  printf '%s\n' "$out" >&2
  return "$rc"
}

package_dump() {
  adb_shell dumpsys package "$PACKAGE"
}

package_uid() {
  package_dump | sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' | head -1 | tr -d '\r'
}

package_lib_dir() {
  package_dump | sed -n 's/.*legacyNativeLibraryDir=\(.*\)$/\1/p' | head -1 | tr -d '\r'
}

package_base_apk() {
  adb_shell pm path "$PACKAGE" | sed -n 's/^package://p' | head -1 | tr -d '\r'
}

package_abi() {
  package_dump | sed -n 's/.*primaryCpuAbi=\([^[:space:]]*\).*/\1/p' | head -1 | tr -d '\r'
}

device_imei() {
  adb_shell service call iphonesubinfo 1 2>/dev/null |
    tr -d '\r' |
    awk -F"'" '{ for (i = 2; i <= NF; i += 2) printf $i }' |
    tr -cd '0-9' |
    head -c 15
}

start_http_helper() {
  helper_dir="$1"
  helper_script="$2"
  uid="$3"
  tmp_host="/tmp/euicc-http-helper-$$.sh"
  tmp_setup_host="/tmp/euicc-http-helper-setup-$$.sh"
  setup_script="/data/local/tmp/euicc-http-helper-setup-$$.sh"
  cat > "$tmp_setup_host" <<EOF
#!/system/bin/sh
rm -rf "$helper_dir"
mkdir -p "$helper_dir" || exit 1
chown "$uid:$uid" "$helper_dir" || exit 1
chmod 700 "$helper_dir" || exit 1
EOF
  "$ADB" -s "$SERIAL" push "$tmp_setup_host" "$setup_script" >/dev/null 2>&1
  rm -f "$tmp_setup_host"
  adb_shell chmod 0755 "$setup_script" >/dev/null
  adb_shell su 0 -c "sh $setup_script" >/dev/null
  adb_shell rm -f "$setup_script" >/dev/null 2>&1 || true

  cat > "$tmp_host" <<'EOF'
#!/system/bin/sh
dir="$1"
while [ ! -f "$dir/stop" ]; do
  for ready in "$dir"/*.ready; do
    [ -e "$ready" ] || continue
    base="${ready%.ready}"
    lock="$base.lock"
    mv "$ready" "$lock" 2>/dev/null || continue
    if /system/bin/curl --config "$base.curl" > "$base.code" 2> "$base.stderr"; then
      :
    else
      rc="$?"
      printf 'curl exit %s: ' "$rc" > "$base.err"
      cat "$base.stderr" >> "$base.err" 2>/dev/null || true
    fi
    touch "$base.done"
    rm -f "$lock"
  done
  sleep 1
done
EOF
  "$ADB" -s "$SERIAL" push "$tmp_host" "$helper_script" >/dev/null 2>&1
  rm -f "$tmp_host"
  adb_shell chmod 0755 "$helper_script" >/dev/null
  adb_shell su 0 -c "sh $helper_script $helper_dir" &
  HTTP_HELPER_PID="$!"
}

stop_http_helper() {
  helper_dir="$1"
  helper_script="$2"
  if [ -n "${HTTP_HELPER_PID:-}" ]; then
    adb_shell su 0 -c "touch $helper_dir/stop" >/dev/null 2>&1 || true
    wait "$HTTP_HELPER_PID" 2>/dev/null || true
    HTTP_HELPER_PID=""
  fi
  adb_shell su 0 -c "rm -rf $helper_dir $helper_script" >/dev/null 2>&1 || true
}

ensure_direct_cli() {
  need_device
  [ -f "$DIRECT_CLI_REMOTE_DEX" ] || {
    cat >&2 <<EOF
ERROR EasyEUICC CLI provider is unavailable, and direct CLI dex is missing:
  $DIRECT_CLI_REMOTE_DEX
Build it with android/easyeuicc-app-process-cli/build-cli.sh and copy it to the remote.
EOF
    return 1
  }
  adb_shell mkdir -p "$(dirname "$DIRECT_CLI_DEVICE_DEX")" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" push "$DIRECT_CLI_REMOTE_DEX" "$DIRECT_CLI_DEVICE_DEX" >/dev/null 2>&1
  adb_shell chmod 0644 "$DIRECT_CLI_DEVICE_DEX" >/dev/null
}

direct_cli() {
  ensure_direct_cli
  uid="$(package_uid)"
  [ -n "$uid" ] || {
    echo "ERROR cannot determine EasyEUICC uid for $PACKAGE" >&2
    return 1
  }
  lib_dir="$(package_lib_dir)"
  base_apk="$(package_base_apk)"
  abi="$(package_abi)"
  imei="${EASYEUICC_IMEI:-}"
  if [ -z "$imei" ]; then
    imei="$(device_imei || true)"
  fi
  helper_dir=""
  helper_script=""
  if [ "${1:-}" = "download" ]; then
    helper_dir="/data/data/$PACKAGE/cache/euicc-http-helper-$$"
    helper_script="/data/local/tmp/euicc-http-helper-$$.sh"
    start_http_helper "$helper_dir" "$helper_script" "$uid"
  fi
  lib_search="$lib_dir"
  if [ -n "$base_apk" ] && [ -n "$abi" ] && [ "$abi" != "null" ]; then
    lib_search="${lib_search:+$lib_search:}$base_apk!/lib/$abi"
  fi
  case "$abi" in
    arm64-v8a|x86_64)
      lib_search="${lib_search:+$lib_search:}/system/lib64:/system/lib"
      ;;
    *)
      lib_search="${lib_search:+$lib_search:}/system/lib:/system/lib64"
      ;;
  esac
  cmd="CLASSPATH=$(shell_quote "$DIRECT_CLI_DEVICE_DEX")"
  if [ -n "$DIRECT_CLI_HTTP_PROXY" ]; then
    cmd="$cmd EUICC_HTTP_PROXY=$(shell_quote "$DIRECT_CLI_HTTP_PROXY")"
  fi
  if [ -n "$helper_dir" ]; then
    cmd="$cmd EUICC_HTTP_HELPER_DIR=$(shell_quote "$helper_dir")"
  fi
  if [ -n "$lib_search" ]; then
    cmd="$cmd LD_LIBRARY_PATH=$(shell_quote "$lib_search")"
    cmd="$cmd $APP_PROCESS -Djava.library.path=$(shell_quote "$lib_search") /system/bin $DIRECT_CLI_CLASS"
  else
    cmd="$cmd $APP_PROCESS /system/bin $DIRECT_CLI_CLASS"
  fi
  cmd="$cmd --package $(shell_quote "$PACKAGE") --reader $(shell_quote "$DIRECT_CLI_READER")"
  if [ -n "$base_apk" ]; then
    cmd="$cmd --apk $(shell_quote "$base_apk")"
  fi
  if [ -n "$lib_search" ]; then
    cmd="$cmd --lib-dir $(shell_quote "$lib_search")"
  fi
  if [ -n "$imei" ]; then
    cmd="$cmd --imei $(shell_quote "$imei")"
  fi
  for arg in "$@"; do
    cmd="$cmd $(shell_arg_expr "$arg")"
  done

  tmp_host="/tmp/euicc-cli-run-$$.sh"
  tmp_device="/data/local/tmp/euicc-cli-run-$$.sh"
  {
    printf '%s\n' '#!/system/bin/sh'
    printf '%s\n' "$cmd"
  } > "$tmp_host"
  "$ADB" -s "$SERIAL" push "$tmp_host" "$tmp_device" >/dev/null 2>&1
  rm -f "$tmp_host"
  adb_shell chmod 0755 "$tmp_device" >/dev/null
  set +e
  adb_shell su "$uid" -c "sh $tmp_device"
  rc="$?"
  set -e
  adb_shell rm -f "$tmp_device" >/dev/null 2>&1 || true
  if [ -n "$helper_dir" ]; then
    stop_http_helper "$helper_dir" "$helper_script"
  fi
  return "$rc"
}

profiles_text() {
  content_read "$CLI_URI/profiles.txt" 2>/dev/null || direct_cli list
}

profiles_json() {
  content_read "$CLI_URI/profiles.json" 2>/dev/null || direct_cli list-json
}

switch_target() {
  target="$1"
  content_read "$CLI_URI/switch.json?target=$(url_encode "$target")" 2>/dev/null || direct_cli switch "$target"
}

switch_exact() {
  name="$1"
  provider="${2:-}"
  content_read "$CLI_URI/switch-exact.json?name=$(url_encode "$name")&provider=$(url_encode "$provider")" 2>/dev/null || direct_cli switch-exact "$name" "$provider"
}

switch_iccid() {
  iccid="$1"
  content_read "$CLI_URI/switch-iccid/$(url_encode "$iccid")" 2>/dev/null || direct_cli switch-iccid "$iccid"
}

ensure_download_proxy() {
  [ -n "$DIRECT_CLI_HTTP_PROXY" ] || return 0
  port="$(printf '%s' "$DIRECT_CLI_HTTP_PROXY" | sed -n \
    -e 's#^http://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' \
    -e 's#^127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' | head -1)"
  if [ -n "$port" ]; then
    "$ADB" -s "$SERIAL" reverse "tcp:$port" "tcp:$port" >/dev/null 2>&1 || true
  fi
}

activation_parse() {
  lua - "${1:-}" "${2:-false}" <<'LUA'
local raw = arg[1] or ""
local dry_run = arg[2] == "true"

local function esc(s)
  s = s or ""
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\n", "\\n"))
end

local function fail(message)
  io.write('{"ok":false,"error":"' .. esc(message) .. '"}\n')
  os.exit(2)
end

local function urldecode(s)
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local decoded = urldecode(raw):gsub("^%s+", ""):gsub("%s+$", "")
local lpa = decoded:match("[Ll][Pp][Aa]:1%$[^%s&\"'<>]+") or decoded
if lpa:sub(1, 4):lower() == "lpa:" then lpa = lpa:sub(5) end

local parts = {}
for part in (lpa .. "$"):gmatch("(.-)%$") do
  parts[#parts + 1] = (part:gsub("^%s+", ""):gsub("%s+$", ""))
end

if parts[1] ~= "1" then fail("Invalid AC_Format") end
if not parts[2] or parts[2] == "" then fail("SM-DP+ is required") end

local confirmation_required = parts[5] == "1"
local normalized = {"1", parts[2], parts[3] or "", parts[4] or ""}
if confirmation_required then normalized[#normalized + 1] = "1" end
while #normalized > 1 and normalized[#normalized] == "" do table.remove(normalized) end
local activation = "LPA:" .. table.concat(normalized, "$")

io.write('{"ok":true')
if dry_run then io.write(',"dryRun":true') end
io.write(',"activationCode":"' .. esc(activation) .. '"')
io.write(',"smdpAddress":"' .. esc(parts[2]) .. '"')
if parts[3] and parts[3] ~= "" then
  io.write(',"matchingId":"' .. esc(parts[3]) .. '"')
else
  io.write(',"matchingId":null')
end
if parts[4] and parts[4] ~= "" then
  io.write(',"oid":"' .. esc(parts[4]) .. '"')
else
  io.write(',"oid":null')
end
io.write(',"confirmationCodeRequired":' .. tostring(confirmation_required) .. '}\n')
LUA
}

download_profile() {
  activation="${1:-}"
  confirmation="${2:-}"
  [ -n "$activation" ] || {
    echo "ERROR missing activation code" >&2
    exit 2
  }
  content_read "$CLI_URI/download.json?activationCode=$(url_encode "$activation")&confirmationCode=$(url_encode "$confirmation")&confirm=true" 2>/dev/null || {
    ensure_download_proxy
    direct_cli download "$activation" "$confirmation"
  }
}

display_mode() {
  mode="${1:-}"
  need_device
  case "$mode" in
    fast)
      adb_shell wm size reset
      adb_shell wm density reset
      echo "OK fast display is stream-side; restored device display overrides"
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

active_netid() {
  adb_shell dumpsys connectivity 2>/dev/null |
    sed -n 's/Active default network: //p' |
    head -1 |
    tr -d '\r'
}

dns_proxy_start() {
  ensure_direct_cli
  start_script="/data/local/tmp/r6c-start-dns-proxy.sh"
  log="/data/local/tmp/r6c-dns-proxy.log"
  pidfile="/data/local/tmp/r6c-dns-proxy.pid"
  tmp_host="/tmp/r6c-start-dns-proxy-$$.sh"
  cat > "$tmp_host" <<EOF
#!/system/bin/sh
pkill -f 'EuiccAppProcessCli dns-proxy' 2>/dev/null || true
rm -f "$log"
export CLASSPATH="$DIRECT_CLI_DEVICE_DEX"
trap '' HUP
$APP_PROCESS /system/bin $DIRECT_CLI_CLASS dns-proxy 127.0.0.1 53 >"$log" 2>&1 &
echo \$! >"$pidfile"
EOF
  "$ADB" -s "$SERIAL" push "$tmp_host" "$start_script" >/dev/null
  rm -f "$tmp_host"
  adb_shell chmod 0755 "$start_script" >/dev/null
  adb_shell su -c "sh $start_script" >/dev/null
  sleep 1

  netid="$(active_netid)"
  if [ -n "$netid" ] && [ "$netid" != "none" ]; then
    adb_shell su -c "ndc resolver setnetdns $netid localdomain 127.0.0.1" >/dev/null 2>&1 || true
  fi
  adb_shell su -c 'setprop net.dns1 127.0.0.1; setprop net.dns2 223.5.5.5; setprop net.dns3 119.29.29.29' >/dev/null 2>&1 || true
  adb_shell settings put global http_proxy :0 >/dev/null 2>&1 || true
  adb_shell settings delete global global_http_proxy_host >/dev/null 2>&1 || true
  adb_shell settings delete global global_http_proxy_port >/dev/null 2>&1 || true
  adb_shell settings put global mobile_data 1 >/dev/null 2>&1 || true
  adb_shell settings put global data_roaming 1 >/dev/null 2>&1 || true
  adb_shell svc data enable >/dev/null 2>&1 || true
  dns_proxy_status
}

dns_proxy_stop() {
  need_device
  adb_shell su -c "pkill -f 'EuiccAppProcessCli dns-proxy' 2>/dev/null || true; rm -f /data/local/tmp/r6c-dns-proxy.pid" >/dev/null 2>&1 || true
  echo "DNS proxy stopped"
}

dns_proxy_status() {
  need_device
  netid="$(active_netid)"
  echo "netid=${netid:-}"
  pid="$(adb_shell su -c 'cat /data/local/tmp/r6c-dns-proxy.pid' 2>/dev/null | tr -d '\r' || true)"
  echo "dns_proxy_pid=$pid"
  if [ -n "$pid" ]; then
    adb_shell su -c "cat /proc/$pid/cmdline" 2>/dev/null | tr '\000' ' ' || true
    echo
  fi
  adb_shell su -c 'cat /data/local/tmp/r6c-dns-proxy.log' 2>/dev/null | head -5 || true
  echo "http_proxy=$(adb_shell settings get global http_proxy 2>/dev/null | tr -d '\r')"
  echo "mobile_data=$(adb_shell settings get global mobile_data 2>/dev/null | tr -d '\r')"
  echo "data_roaming=$(adb_shell settings get global data_roaming 2>/dev/null | tr -d '\r')"
  if [ -n "$netid" ] && [ "$netid" != "none" ]; then
    adb_shell su -c 'dumpsys netd' 2>/dev/null | grep -A10 -B2 " $netid PHYSICAL" | head -40 || true
  fi
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
  download-parse)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    activation_parse "$2" false
    ;;
  download-dry-run)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    activation_parse "$2" true
    ;;
  download)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    download_profile "$2" "${3:-}"
    ;;
  dns)
    case "${2:-status}" in
      start)
        dns_proxy_start
        ;;
      stop)
        dns_proxy_stop
        ;;
      status|'')
        dns_proxy_status
        ;;
      *)
        echo "ERROR unknown dns command: ${2:-}" >&2
        usage >&2
        exit 2
        ;;
    esac
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
