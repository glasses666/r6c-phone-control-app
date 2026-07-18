#!/bin/sh
set -eu

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_SUPPORT_DIR="${R6C_APP_SUPPORT_DIR:-$HOME/Library/Application Support/R6CPhoneControl}"
SCRCPY_DIR="${R6C_SCRCPY_DIR:-$APP_SUPPORT_DIR/r6c-scrcpy}"
ANDROID_CONTROL_DIR="${R6C_ANDROID_CONTROL_DIR:-$APP_SUPPORT_DIR/r6c-android-control}"
SSH_KEY="${R6C_SSH_KEY:-$SCRCPY_DIR/ssh_ed25519}"
SSH_HOST="${R6C_SSH_HOST:-}"
SSH_PORT="${R6C_SSH_PORT:-22}"
ANDROID_SERIAL="${R6C_ANDROID_SERIAL:-}"
SCRCPY_PORT="${R6C_SCRCPY_PORT:-27186}"
SCREEN_NAME="${R6C_SCREEN_NAME:-r6c-scrcpy}"
SCRCPY_LOG="${R6C_SCRCPY_LOG:-/tmp/r6c-scrcpy-screen.log}"
SCRCPY_PID_FILE="${R6C_SCRCPY_PID_FILE:-/tmp/r6c-scrcpy.pid}"
STREAM_LOG="${R6C_STREAM_LOG:-/tmp/r6c-phone-control-stream.log}"
STREAM_PID_FILE="${R6C_STREAM_PID_FILE:-/tmp/r6c-phone-control-stream.pid}"
H264_STREAM_PID_FILE="${R6C_H264_STREAM_PID_FILE:-/tmp/r6c-phone-control-h264-stream.pid}"
SCRCPY_SERVER_PATH="${R6C_SCRCPY_SERVER_PATH:-$BASE_DIR/Resources/scrcpy-server}"
SCRCPY_CONTROL_PORT="${R6C_SCRCPY_CONTROL_PORT:-27283}"
SCRCPY_CONTROL_SCID="${R6C_SCRCPY_CONTROL_SCID:-00000001}"
SCRCPY_EMBEDDED_PORT="${R6C_SCRCPY_EMBEDDED_PORT:-27284}"
SCRCPY_EMBEDDED_SCID="${R6C_SCRCPY_EMBEDDED_SCID:-00000002}"
SCRCPY_EMBEDDED_PID_FILE="${R6C_SCRCPY_EMBEDDED_PID_FILE:-/tmp/r6c-phone-control-scrcpy-embedded.pid}"
BUNDLED_SCRCPY_SCRIPT="$BASE_DIR/Resources/start-scrcpy-r6c.sh"
SCRCPY_SCRIPT="${R6C_SCRCPY_SCRIPT:-$SCRCPY_DIR/start-scrcpy-r6c.sh}"
WEB_URL_FILE_FAST="$ANDROID_CONTROL_DIR/public-url-fast.txt"
WEB_URL_FILE="$ANDROID_CONTROL_DIR/public-url.txt"
SSH_TIMEOUT="${R6C_SSH_TIMEOUT:-30}"
SSH_CONTROL_ID="$(printf '%s:%s:%s' "$SSH_HOST" "$SSH_PORT" "$SSH_KEY" | cksum | awk '{ print $1 }')"
SSH_CONTROL_PATH="${R6C_SSH_CONTROL_PATH:-/tmp/r6c-phone-control-ssh-$SSH_CONTROL_ID.sock}"
ADB_BIN="${R6C_ADB:-}"
if [ -z "$ADB_BIN" ]; then
  for candidate in /opt/homebrew/bin/adb /usr/local/bin/adb /usr/bin/adb; do
    [ -x "$candidate" ] && { ADB_BIN="$candidate"; break; }
  done
fi

is_local_connection() {
  [ -z "$SSH_HOST" ]
}

ssh_cmd() {
  [ -n "$SSH_HOST" ] || {
    echo "ERROR set R6C_SSH_HOST or add a remote in the app" >&2
    exit 2
  }
  ssh \
    -i "$SSH_KEY" \
    -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=8 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=1 \
    -o ControlMaster=auto \
    -o ControlPersist=300 \
    -S "$SSH_CONTROL_PATH" \
    "$@"
}

ssh_r6c() {
  tmp="$(mktemp)"
  ssh_cmd "$SSH_HOST" "$@" >"$tmp" 2>&1 &
  pid="$!"
  ticks=0
  limit=$((SSH_TIMEOUT * 10))
  while kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$ticks" -ge "$limit" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      cat "$tmp"
      rm -f "$tmp"
      echo "ERROR ssh command timed out after ${SSH_TIMEOUT}s" >&2
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  set +e
  wait "$pid"
  rc="$?"
  set -e
  cat "$tmp"
  rm -f "$tmp"
  return "$rc"
}

android_host_shell() {
  command="$1"
  if is_local_connection; then
    [ -x "$ADB_BIN" ] || {
      echo "ERROR adb is not installed on this Mac" >&2
      return 127
    }
    PATH="$(dirname "$ADB_BIN"):$PATH" /bin/sh -c "$command"
  else
    ssh_r6c "$command"
  fi
}

android_host_stream() {
  command="$1"
  if is_local_connection; then
    [ -x "$ADB_BIN" ] || {
      echo "ERROR adb is not installed on this Mac" >&2
      return 127
    }
    PATH="$(dirname "$ADB_BIN"):$PATH" /bin/sh -c "$command"
  else
    ssh_cmd "$SSH_HOST" "$command"
  fi
}

copy_to_android_host() {
  source="$1"
  destination="$2"
  if is_local_connection; then
    cp "$source" "$destination"
  else
    scp -i "$SSH_KEY" -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$source" "$SSH_HOST:$destination"
  fi
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

require_scrcpy_script() {
  if [ ! -x "$SCRCPY_SCRIPT" ] && [ -x "$BUNDLED_SCRCPY_SCRIPT" ]; then
    SCRCPY_SCRIPT="$BUNDLED_SCRCPY_SCRIPT"
  fi
  [ -x "$SCRCPY_SCRIPT" ] || {
    echo "ERROR missing scrcpy script: $SCRCPY_SCRIPT" >&2
    exit 2
  }
}

read_web_url() {
  if [ -r "$WEB_URL_FILE_FAST" ]; then
    cat "$WEB_URL_FILE_FAST"
  elif [ -r "$WEB_URL_FILE" ]; then
    cat "$WEB_URL_FILE"
  else
    echo ""
  fi
}

web_url_available() {
  [ -s "$WEB_URL_FILE_FAST" ] || [ -s "$WEB_URL_FILE" ]
}

adb_status() {
  serial="$(selected_serial || true)"
  if [ -n "$serial" ]; then
    SSH_TIMEOUT=12 android_host_shell 'ADB_VENDOR_KEYS=/root/.android adb devices -l 2>&1' |
      awk -v serial="$serial" '
        $1 == serial && / device / { found="connected"; detail=$0 }
        $1 == serial && / unauthorized/ { found="unauthorized"; detail=$0 }
        END {
          if (found == "") found="missing";
          print "adb=" found;
          if (detail != "") print "adb_detail=" detail;
        }'
  else
    SSH_TIMEOUT=12 android_host_shell 'ADB_VENDOR_KEYS=/root/.android adb devices -l 2>&1' |
      awk '
        / device / { found="connected"; detail=$0 }
        / unauthorized/ { found="unauthorized"; detail=$0 }
        END {
          if (found == "") found="missing";
          print "adb=" found;
          if (detail != "") print "adb_detail=" detail;
        }'
  fi
}

cmd_devices() {
  SSH_TIMEOUT=12 android_host_shell 'ADB_VENDOR_KEYS=/root/.android adb devices -l 2>&1' |
    awk '
      NR > 1 && $1 != "" {
        state=$2
        model=""
        product=""
        device=""
        for (i = 3; i <= NF; i++) {
          if ($i ~ /^model:/) { model=substr($i, 7) }
          if ($i ~ /^product:/) { product=substr($i, 9) }
          if ($i ~ /^device:/) { device=substr($i, 8) }
        }
        printf "DEVICE serial=\"%s\" state=\"%s\" model=\"%s\" product=\"%s\" device=\"%s\"\n", $1, state, model, product, device
      }'
}

selected_serial() {
  if [ -n "$ANDROID_SERIAL" ]; then
    printf '%s\n' "$ANDROID_SERIAL"
    return 0
  fi
  SSH_TIMEOUT=12 android_host_shell 'ADB_VENDOR_KEYS=/root/.android adb devices 2>&1' |
    awk 'NR > 1 && $2 == "device" { print $1; exit }'
}

require_serial() {
  serial="$(selected_serial || true)"
  [ -n "$serial" ] || {
    echo "ERROR no adb device in device state" >&2
    exit 1
  }
  printf '%s\n' "$serial"
}

adb_shell_raw() {
  serial="$1"
  shift
  [ "$#" -gt 0 ] || {
    echo "ERROR missing shell command" >&2
    exit 2
  }
  command="$*"
  SSH_TIMEOUT="${R6C_ADB_SHELL_TIMEOUT:-30}" android_host_shell "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell sh -c $(shell_quote "$command") 2>&1"
}

number() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

key_name() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

input_text_arg() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/ /%s/g'
}

file_id() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

input_fifo() {
  printf '/tmp/r6c-input-%s.fifo\n' "$(file_id "$1")"
}

input_pid_file() {
  printf '/tmp/r6c-input-%s.pid\n' "$(file_id "$1")"
}

input_log_file() {
  printf '/tmp/r6c-input-%s.log\n' "$(file_id "$1")"
}

send_input_relay() {
  serial="$1"
  command="$2"
  fifo="$(input_fifo "$serial")"
  pidfile="$(input_pid_file "$serial")"
  log="$(input_log_file "$serial")"
  # ponytail: one FIFO per serial; replace with a real input daemon if concurrent clients matter.
  SSH_TIMEOUT=3 android_host_shell "serial=$(shell_quote "$serial"); fifo=$(shell_quote "$fifo"); pidfile=$(shell_quote "$pidfile"); log=$(shell_quote "$log"); if [ ! -p \"\$fifo\" ] || ! kill -0 \"\$(cat \"\$pidfile\" 2>/dev/null)\" 2>/dev/null; then rm -f \"\$fifo\"; mkfifo \"\$fifo\"; (while :; do cat \"\$fifo\"; done | ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell >\"\$log\" 2>&1) & echo \$! > \"\$pidfile\"; fi; printf '%s\n' $(shell_quote "$command") > \"\$fifo\"" >/dev/null
}

stop_input_relay() {
  serial="$1"
  fifo="$(input_fifo "$serial")"
  pidfile="$(input_pid_file "$serial")"
  SSH_TIMEOUT=3 android_host_shell "fifo=$(shell_quote "$fifo"); pidfile=$(shell_quote "$pidfile"); if [ -s \"\$pidfile\" ]; then kill \"\$(cat \"\$pidfile\")\" >/dev/null 2>&1 || true; fi; rm -f \"\$fifo\" \"\$pidfile\"" >/dev/null
}

scrcpy_status() {
  serial="$(selected_serial || true)"
  scrcpy_running=0
  if ps auxww | grep -E "scrcpy .*--serial $serial" | grep -v grep >/dev/null 2>&1; then
    echo "scrcpy=running"
    scrcpy_running=1
  else
    echo "scrcpy=stopped"
  fi

  if [ -s "$SCRCPY_PID_FILE" ] && kill -0 "$(cat "$SCRCPY_PID_FILE")" >/dev/null 2>&1; then
    echo "screen=running"
  elif [ "$scrcpy_running" -eq 1 ]; then
    echo "screen=running"
  elif screen -ls 2>/dev/null | grep -q "[.]$SCREEN_NAME"; then
    echo "screen=running"
  else
    echo "screen=stopped"
  fi
}

cmd_capture_screen() {
  serial="$(require_serial)"
  out="${1:-/tmp/r6c-phone-control-screen.png}"
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "${out}.XXXXXX")"
  if android_host_stream "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") exec-out screencap -p" >"$tmp"; then
    [ -s "$tmp" ] || {
      rm -f "$tmp"
      echo "ERROR empty screen capture" >&2
      return 1
    }
    mv "$tmp" "$out"
    echo "screen=$out"
  else
    rc="$?"
    rm -f "$tmp"
    return "$rc"
  fi
}

screenrecord_size_arg() {
  size="${1:-}"
  [ -z "$size" ] && return 0
  width="${size%x*}"
  height="${size#*x}"
  if [ "$width" = "$size" ] || [ -z "$width" ] || [ -z "$height" ] || [ "${height#*x}" != "$height" ]; then
    echo "ERROR invalid screenrecord size: $size" >&2
    exit 2
  fi
  case "$width$height" in
    *[!0-9]*)
      echo "ERROR invalid screenrecord size: $size" >&2
      exit 2
      ;;
  esac
  printf ' --size %s' "$(shell_quote "$size")"
}

kill_process_tree() (
  root="${1:-}"
  [ -n "$root" ] || return 0
  for child in $(pgrep -P "$root" 2>/dev/null || true); do
    kill_process_tree "$child"
  done
  kill "$root" >/dev/null 2>&1 || true
)

stop_stream_processes() {
  frame="${1:-/tmp/r6c-phone-control-stream.jpg}"
  if [ -s "$STREAM_PID_FILE" ]; then
    kill_process_tree "$(cat "$STREAM_PID_FILE")"
    rm -f "$STREAM_PID_FILE"
  fi
  for pid in $(pgrep -f "$frame" 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    [ -n "${PPID:-}" ] && [ "$pid" = "$PPID" ] && continue
    kill_process_tree "$pid"
  done
}

cmd_start_stream() {
  serial="$(require_serial)"
  frame="${1:-/tmp/r6c-phone-control-stream.jpg}"
  command -v ffmpeg >/dev/null 2>&1 || {
    echo "ERROR ffmpeg is required for embedded stream" >&2
    exit 1
  }
  mkdir -p "$(dirname "$frame")"
  stop_stream_processes "$frame"
  rm -f "$frame"
  : > "$STREAM_LOG"

  size_arg="$(screenrecord_size_arg "${R6C_STREAM_SIZE:-}")"
  remote_cmd="ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") exec-out screenrecord --output-format=h264 --time-limit ${R6C_STREAM_SEGMENT_SECONDS:-2} --bit-rate ${R6C_STREAM_BITRATE:-4M}${size_arg} -"
  if is_local_connection; then
    source_cmd="$(shell_quote "$ADB_BIN") -s $(shell_quote "$serial") exec-out screenrecord --output-format=h264 --time-limit ${R6C_STREAM_SEGMENT_SECONDS:-2} --bit-rate ${R6C_STREAM_BITRATE:-4M}${size_arg} -"
  else
    source_cmd="ssh -i $(shell_quote "$SSH_KEY") -p $(shell_quote "$SSH_PORT") -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o ControlMaster=auto -o ControlPersist=300 -S $(shell_quote "$SSH_CONTROL_PATH") $(shell_quote "$SSH_HOST") $(shell_quote "$remote_cmd")"
  fi
  stream_cmd="while :; do $source_cmd | ffmpeg -y -hide_banner -loglevel error -f h264 -i pipe:0 -vf fps=${R6C_STREAM_FPS:-30},format=yuvj420p -threads 1 -q:v ${R6C_STREAM_JPEG_QUALITY:-4} -update 1 -atomic_writing 1 $(shell_quote "$frame"); sleep 0.05; done"
  nohup /bin/zsh -lc "$stream_cmd" >>"$STREAM_LOG" 2>&1 &
  echo "$!" > "$STREAM_PID_FILE"
  echo "stream=starting"
  echo "frame=$frame"
}

cmd_h264_stream() {
  serial="$(require_serial)"
  segment="${R6C_H264_STREAM_SEGMENT_SECONDS:-120}"
  bitrate="${R6C_H264_STREAM_BITRATE:-8M}"
  size_arg="$(screenrecord_size_arg "${R6C_H264_STREAM_SIZE:-}")"
  child=""
  echo "$$" > "$H264_STREAM_PID_FILE"
  cleanup_h264_stream() {
    [ -n "$child" ] && kill_process_tree "$child" >/dev/null 2>&1 || true
    rm -f "$H264_STREAM_PID_FILE"
  }
  trap 'cleanup_h264_stream; exit 0' INT TERM
  trap 'cleanup_h264_stream' EXIT

  while :; do
    android_host_stream "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") exec-out screenrecord --output-format=h264 --time-limit $(shell_quote "$segment") --bit-rate $(shell_quote "$bitrate")${size_arg} -" &
    child="$!"
    wait "$child" || true
    child=""
    sleep 0.02
  done
}

cmd_stop_h264_stream() {
  if [ -s "$H264_STREAM_PID_FILE" ]; then
    kill_process_tree "$(cat "$H264_STREAM_PID_FILE")"
    rm -f "$H264_STREAM_PID_FILE"
  fi
  for pid in $(ps -axo pid=,command= | awk '/\/r6c-phone-control[.]sh h264-stream$/ { print $1 }'); do
    [ "$pid" = "$$" ] && continue
    [ -n "${PPID:-}" ] && [ "$pid" = "$PPID" ] && continue
    kill_process_tree "$pid"
  done
  echo "OK stopped native stream"
}

cmd_stop_stream() {
  stop_stream_processes
  echo "OK stopped stream"
}

cmd_stop_input() {
  serial="$(selected_serial || true)"
  [ -n "$serial" ] || {
    echo "OK no input relay"
    return 0
  }
  stop_input_relay "$serial" || true
  echo "OK stopped input relay"
}

cmd_stop_all_input() {
  SSH_TIMEOUT=5 android_host_shell 'for pidfile in /tmp/r6c-input-*.pid; do [ -e "$pidfile" ] || continue; kill "$(cat "$pidfile")" >/dev/null 2>&1 || true; done; rm -f /tmp/r6c-input-*.fifo /tmp/r6c-input-*.pid' >/dev/null || true
  echo "OK stopped all input relays"
}

scrcpy_server_path() {
  if [ -f "$SCRCPY_SERVER_PATH" ]; then
    printf '%s\n' "$SCRCPY_SERVER_PATH"
    return 0
  fi
  for path in \
    /opt/homebrew/share/scrcpy/scrcpy-server \
    /usr/local/share/scrcpy/scrcpy-server \
    /opt/homebrew/Cellar/scrcpy/*/share/scrcpy/scrcpy-server \
    /usr/local/Cellar/scrcpy/*/share/scrcpy/scrcpy-server
  do
    [ -f "$path" ] && {
      printf '%s\n' "$path"
      return 0
    }
  done
  echo "ERROR missing scrcpy-server" >&2
  return 1
}

cmd_scrcpy_control_stream() {
  serial="$(require_serial)"
  server="$(scrcpy_server_path)"
  remote_server="/tmp/r6c-phone-control-scrcpy-server"
  device_server="/data/local/tmp/scrcpy-server.jar"
  copy_to_android_host "$server" "$remote_server" >/dev/null
  android_host_stream "set -eu; serial=$(shell_quote "$serial"); port=$(shell_quote "$SCRCPY_CONTROL_PORT"); scid=$(shell_quote "$SCRCPY_CONTROL_SCID"); remote_server=$(shell_quote "$remote_server"); device_server=$(shell_quote "$device_server"); log=/tmp/r6c-scrcpy-control-\$serial.log; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" push \"\$remote_server\" \"\$device_server\" >/dev/null 2>&1; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward --remove tcp:\"\$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward tcp:\"\$port\" localabstract:scrcpy_\"\$scid\" >/dev/null; (ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell CLASSPATH=\"\$device_server\" app_process / com.genymobile.scrcpy.Server 4.0 scid=\"\$scid\" log_level=warn video=false audio=false control=true tunnel_forward=true cleanup=false power_on=true clipboard_autosync=false send_device_meta=false send_dummy_byte=false >\"\$log\" 2>&1 &) ; sleep 1; exec nc 127.0.0.1 \"\$port\""
}

cmd_scrcpy_embedded_stream() {
  serial="$(require_serial)"
  server="$(scrcpy_server_path)"
  remote_server="/tmp/r6c-phone-control-scrcpy-server"
  device_server="/data/local/tmp/scrcpy-server.jar"
  echo "$$" > "$SCRCPY_EMBEDDED_PID_FILE"
  trap 'rm -f "$SCRCPY_EMBEDDED_PID_FILE"' EXIT
  copy_to_android_host "$server" "$remote_server" >/dev/null
  android_host_stream "set -eu; serial=$(shell_quote "$serial"); port=$(shell_quote "$SCRCPY_EMBEDDED_PORT"); scid=$(shell_quote "$SCRCPY_EMBEDDED_SCID"); remote_server=$(shell_quote "$remote_server"); device_server=$(shell_quote "$device_server"); log=/tmp/r6c-scrcpy-embedded-\$serial.log; pkill -f \"nc 127.0.0.1 \$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" push \"\$remote_server\" \"\$device_server\" >/dev/null 2>&1; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward --remove tcp:\"\$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward tcp:\"\$port\" localabstract:scrcpy_\"\$scid\" >/dev/null; (ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell CLASSPATH=\"\$device_server\" app_process / com.genymobile.scrcpy.Server 4.0 scid=\"\$scid\" log_level=warn audio=false control=true tunnel_forward=true cleanup=false power_on=true clipboard_autosync=false raw_stream=true video_bit_rate=8000000 max_fps=60 >\"\$log\" 2>&1 &) ; sleep 1; tail -f /dev/null | nc 127.0.0.1 \"\$port\" & video_pid=\$!; sleep 1; trap 'kill \"\$video_pid\" >/dev/null 2>&1 || true; pkill -f \"nc 127.0.0.1 \$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true; wait \"\$video_pid\" >/dev/null 2>&1 || true' INT TERM EXIT; nc 127.0.0.1 \"\$port\" >/dev/null || true"
}

cmd_stop_scrcpy_embedded_stream() {
  if [ -s "$SCRCPY_EMBEDDED_PID_FILE" ]; then
    kill_process_tree "$(cat "$SCRCPY_EMBEDDED_PID_FILE")"
    rm -f "$SCRCPY_EMBEDDED_PID_FILE"
  fi
  for pid in $(ps -axo pid=,command= | awk '/\/r6c-phone-control[.]sh scrcpy-embedded-stream$/ { print $1 }'); do
    [ "$pid" = "$$" ] && continue
    [ -n "${PPID:-}" ] && [ "$pid" = "$PPID" ] && continue
    kill_process_tree "$pid"
  done
  serial="$(selected_serial || true)"
  if [ -n "$serial" ]; then
    SSH_TIMEOUT=5 android_host_shell "port=$(shell_quote "$SCRCPY_EMBEDDED_PORT"); scid=$(shell_quote "$SCRCPY_EMBEDDED_SCID"); pkill -f \"nc 127.0.0.1 \$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") forward --remove tcp:\"\$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true" >/dev/null || true
  fi
  echo "OK stopped embedded scrcpy stream"
}

cmd_tap() {
  serial="$(require_serial)"
  x="${1:-}"
  y="${2:-}"
  number "$x" && number "$y" || {
    echo "ERROR bad tap coordinates" >&2
    exit 2
  }
  send_input_relay "$serial" "input tap $x $y" ||
    SSH_TIMEOUT=8 android_host_shell "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input tap $x $y >/dev/null 2>&1"
  echo "OK tap ${x},${y}"
}

cmd_swipe() {
  serial="$(require_serial)"
  x1="${1:-}"
  y1="${2:-}"
  x2="${3:-}"
  y2="${4:-}"
  ms="${5:-250}"
  number "$x1" && number "$y1" && number "$x2" && number "$y2" && number "$ms" || {
    echo "ERROR bad swipe coordinates" >&2
    exit 2
  }
  send_input_relay "$serial" "input swipe $x1 $y1 $x2 $y2 $ms" ||
    SSH_TIMEOUT=8 android_host_shell "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input swipe $x1 $y1 $x2 $y2 $ms >/dev/null 2>&1"
  echo "OK swipe ${x1},${y1} ${x2},${y2}"
}

cmd_keyevent() {
  key="${1:-}"
  key_name "$key" || {
    echo "ERROR bad keyevent name" >&2
    exit 2
  }
  serial="$(require_serial)"
  send_input_relay "$serial" "input keyevent $key" ||
    SSH_TIMEOUT=8 android_host_shell "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input keyevent $(shell_quote "$key") >/dev/null 2>&1"
  echo "OK keyevent ${key}"
}

cmd_stayon() {
  mode="${1:-true}"
  case "$mode" in
    true|false) ;;
    *)
      echo "ERROR bad stayon mode" >&2
      exit 2
      ;;
  esac
  serial="$(require_serial)"
  send_input_relay "$serial" "svc power stayon $mode" ||
    SSH_TIMEOUT=8 android_host_shell "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell svc power stayon $(shell_quote "$mode") >/dev/null 2>&1"
  echo "OK stayon ${mode}"
}

cmd_text() {
  text="${1:-}"
  [ -n "$text" ] || {
    echo "ERROR missing input text" >&2
    exit 2
  }
  arg="$(input_text_arg "$text")"
  serial="$(require_serial)"
  send_input_relay "$serial" "input text $(shell_quote "$arg")" ||
    SSH_TIMEOUT=8 android_host_shell "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input text $(shell_quote "$arg") >/dev/null 2>&1"
  echo "OK text"
}

cmd_status() {
  adb_status || {
    echo "adb=error"
  }
  cmd_phone_info || true
  scrcpy_status
  if is_local_connection; then
    echo "web=local-unavailable"
  elif web_url_available; then
    echo "web=available"
  else
    echo "web=missing"
  fi
}

phone_info_payload() {
  cat <<'R6C_PHONE_INFO'
battery="$(dumpsys battery 2>/dev/null || true)"
level="$(printf "%s\n" "$battery" | awk -F: "/^[[:space:]]*level:/{gsub(/[[:space:]]/, \"\", \$2); print \$2; exit}")"
status="$(printf "%s\n" "$battery" | awk -F: "/^[[:space:]]*status:/{gsub(/[[:space:]]/, \"\", \$2); print \$2; exit}")"
case "$status" in
  2) charge="charging" ;;
  3) charge="discharging" ;;
  4) charge="not charging" ;;
  5) charge="full" ;;
  "") charge="unknown" ;;
  *) charge="status $status" ;;
esac
[ -n "$level" ] && echo "battery=${level}% ${charge}" || echo "battery=unknown"

setting_state() {
  value="$1"
  case "$value" in
    0|false|disabled) printf off ;;
    ""|null) printf unknown ;;
    *) printf on ;;
  esac
}

mobile="$(settings list global 2>/dev/null | awk -F= '
  /^mobile_data[0-9]+=/ { seen=1; if ($2 != "0") on=1 }
  END {
    if (seen) { print on ? 1 : 0 }
  }')"
[ -n "$mobile" ] || mobile="$(settings get global mobile_data 2>/dev/null || true)"
wifi="$(settings get global wifi_on 2>/dev/null || true)"
bluetooth="$(settings get global bluetooth_on 2>/dev/null || true)"
echo "mobile_data=$(setting_state "$mobile")"
echo "wifi=$(setting_state "$wifi")"
echo "bluetooth=$(setting_state "$bluetooth")"

carrier="$(getprop gsm.operator.alpha 2>/dev/null | tr "," "/" | sed "s/[[:space:]]*$//")"
tech="$(getprop gsm.network.type 2>/dev/null | tr "," "/" | sed "s/[[:space:]]*$//")"
active="$(dumpsys connectivity 2>/dev/null | awk -F": " "/Active default network:/{print \$2; exit}")"
data_state="$(dumpsys telephony.registry 2>/dev/null | awk -F= "/mDataConnectionState=/{print \$2; exit}")"
case "$data_state" in
  0) data_label="disconnected" ;;
  1) data_label="connecting" ;;
  2) data_label="connected" ;;
  3) data_label="suspended" ;;
  *) data_label="unknown" ;;
esac
[ -n "$carrier" ] || carrier="unknown"
[ -n "$tech" ] || tech="unknown"
[ -n "$active" ] || active="unknown"
echo "carrier=$carrier"
echo "network=$tech $data_label; default=$active"
R6C_PHONE_INFO
}

run_device_payload() {
  serial="$1"
  host_script="$2"
  device_script="$3"
  payload="$4"
  timeout="$5"
  if is_local_connection; then
    printf '%s\n' "$payload" > "$host_script"
    "$ADB_BIN" -s "$serial" push "$host_script" "$device_script" >/dev/null 2>&1
    if "$ADB_BIN" -s "$serial" shell sh "$device_script"; then
      rc=0
    else
      rc="$?"
    fi
    rm -f "$host_script"
    return "$rc"
  fi
  SSH_TIMEOUT="$timeout" android_host_shell "set -eu
printf '%s\n' $(shell_quote "$payload") > $(shell_quote "$host_script")
ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") push $(shell_quote "$host_script") $(shell_quote "$device_script") >/dev/null 2>&1
ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell sh $(shell_quote "$device_script")
rm -f $(shell_quote "$host_script")
"
}

cmd_phone_info() {
  serial="$(require_serial)"
  remote_script="/tmp/r6c-phone-info-$(file_id "$serial").sh"
  device_script="/data/local/tmp/r6c-phone-info.sh"
  payload="$(phone_info_payload)"
  run_device_payload "$serial" "$remote_script" "$device_script" "$payload" 18
}

phone_messages_payload() {
  cat <<'R6C_PHONE_MESSAGES'
set -eu

run_sms_query() {
  rows="$(content query --uri content://sms --projection address,date,type,body --sort "date DESC" 2>/dev/null || true)"
  if printf '%s\n' "$rows" | grep -q '^Row:'; then
    printf '%s\n' "$rows"
    return 0
  fi
  su -c 'content query --uri content://sms --projection address,date,type,body --sort "date DESC"' 2>/dev/null || true
}

run_sms_query | awk -v limit="$limit" '
BEGIN { count = 0 }
/^Row:/ {
  line = $0
  sub(/^Row: [0-9]+ /, "", line)

  address = line
  sub(/^address=/, "", address)
  sub(/, date=[0-9]+, type=[0-9]+, body=.*/, "", address)

  date = line
  sub(/^address=.*[, ]date=/, "", date)
  sub(/, type=[0-9]+, body=.*/, "", date)

  type = line
  sub(/^address=.*[, ]date=[0-9]+, type=/, "", type)
  sub(/, body=.*/, "", type)

  body = line
  sub(/^address=.*[, ]date=[0-9]+, type=[0-9]+, body=/, "", body)

  gsub(/\t|\r|\n/, " ", address)
  gsub(/\t|\r|\n/, " ", date)
  gsub(/\t|\r|\n/, " ", type)
  gsub(/\t|\r|\n/, " ", body)

  printf "SMS\t%s\t%s\t%s\t%s\n", date, address, type, body
  count++
  if (count >= limit) exit
}
END { if (count == 0) exit 1 }
'
R6C_PHONE_MESSAGES
}

cmd_messages() {
  limit="${1:-20}"
  number "$limit" && [ "$limit" -gt 0 ] || {
    echo "ERROR bad message limit" >&2
    exit 2
  }
  serial="$(require_serial)"
  remote_script="/tmp/r6c-phone-messages-$(file_id "$serial").sh"
  device_script="/data/local/tmp/r6c-phone-messages.sh"
  payload="limit=$limit
$(phone_messages_payload)"
  run_device_payload "$serial" "$remote_script" "$device_script" "$payload" 30
}

cmd_net() {
  target="${1:-}"
  mode="${2:-}"
  case "$mode" in
    on|enable|enabled|true|1) action="enable"; label="on" ;;
    off|disable|disabled|false|0) action="disable"; label="off" ;;
    *)
      echo "ERROR expected on/off network mode" >&2
      exit 2
      ;;
  esac

  serial="$(require_serial)"
  case "$target" in
    mobile|data|mobile-data)
      adb_shell_raw "$serial" "svc data $action" >/dev/null
      echo "OK mobile_data=$label"
      ;;
    wifi|wi-fi)
      adb_shell_raw "$serial" "svc wifi $action" >/dev/null
      echo "OK wifi=$label"
      ;;
    bluetooth|bt)
      adb_shell_raw "$serial" "cmd bluetooth_manager $action >/dev/null 2>&1 || settings put global bluetooth_on $( [ "$label" = on ] && echo 1 || echo 0 )" >/dev/null
      echo "OK bluetooth=$label"
      ;;
    *)
      echo "ERROR expected network target mobile|wifi|bluetooth" >&2
      exit 2
      ;;
  esac
  cmd_phone_info
}

cmd_shell() {
  [ "$#" -gt 0 ] || {
    echo "ERROR missing shell command" >&2
    exit 2
  }
  serial="$(require_serial)"
  remote_script="/tmp/r6c-phone-shell-$(file_id "$serial").sh"
  device_script="/data/local/tmp/r6c-phone-shell.sh"
  payload="export PATH=/sbin:/system/sbin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin:\$PATH
$*"
  run_device_payload "$serial" "$remote_script" "$device_script" "$payload" "${R6C_ADB_SHELL_TIMEOUT:-120}"
}

cmd_kali_shell() {
  [ "$#" -gt 0 ] || {
    echo "ERROR missing Kali shell command" >&2
    exit 2
  }
  serial="$(require_serial)"
  remote_script="/tmp/r6c-kali-shell-$(file_id "$serial").sh"
  device_script="/data/local/tmp/r6c-kali-shell.sh"
  kali_command="$*"
  chroot_command="busybox chroot /data/local/nhsystem/kali-arm64 /bin/bash -lc $(shell_quote "$kali_command")"
  payload="su -c $(shell_quote "$chroot_command")"
  run_device_payload "$serial" "$remote_script" "$device_script" "$payload" "${R6C_ADB_SHELL_TIMEOUT:-180}"
}

stop_scrcpy_processes() {
  serial="$(selected_serial || true)"
  screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
  if [ -s "$SCRCPY_PID_FILE" ]; then
    pid="$(cat "$SCRCPY_PID_FILE")"
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$pid" >/dev/null 2>&1 || true
    rm -f "$SCRCPY_PID_FILE"
  fi
  if [ -n "$serial" ]; then
    pkill -f "scrcpy .*--serial $serial" >/dev/null 2>&1 || true
  fi
  ssh -S /tmp/r6c-scrcpy-ssh-ctl -O exit "$SSH_HOST" >/dev/null 2>&1 || true
}

cmd_start_scrcpy() {
  serial="$(require_serial)"
  window_x="${1:-}"
  window_y="${2:-}"
  window_w="${3:-}"
  window_h="${4:-}"
  stop_scrcpy_processes
  : > "$SCRCPY_LOG"
  if is_local_connection; then
    scrcpy_bin=""
    for candidate in /opt/homebrew/bin/scrcpy /usr/local/bin/scrcpy; do
      [ -x "$candidate" ] && { scrcpy_bin="$candidate"; break; }
    done
    [ -n "$scrcpy_bin" ] || { echo "ERROR scrcpy is not installed on this Mac" >&2; exit 127; }
    scrcpy_cmd="$(shell_quote "$scrcpy_bin") --serial $(shell_quote "$serial")"
    if [ -n "$window_x" ] && [ -n "$window_y" ] && [ -n "$window_w" ] && [ -n "$window_h" ]; then
      scrcpy_cmd="$scrcpy_cmd --window-title 'R6C Docked scrcpy' --window-borderless --window-x $(shell_quote "$window_x") --window-y $(shell_quote "$window_y") --window-width $(shell_quote "$window_w") --window-height $(shell_quote "$window_h")"
    fi
  else
    require_scrcpy_script
    scrcpy_cmd="R6C_SCRCPY_DIR=$(shell_quote "$SCRCPY_DIR") R6C_SSH_KEY=$(shell_quote "$SSH_KEY") R6C_SSH_HOST=$(shell_quote "$SSH_HOST") R6C_SSH_PORT=$(shell_quote "$SSH_PORT") R6C_ANDROID_SERIAL=$(shell_quote "$serial") R6C_SCRCPY_PORT=$(shell_quote "$SCRCPY_PORT") R6C_SCRCPY_VERBOSITY=debug $(shell_quote "$SCRCPY_SCRIPT")"
    if [ -n "$window_x" ] && [ -n "$window_y" ] && [ -n "$window_w" ] && [ -n "$window_h" ]; then
      scrcpy_cmd="R6C_SCRCPY_DIR=$(shell_quote "$SCRCPY_DIR") R6C_SSH_KEY=$(shell_quote "$SSH_KEY") R6C_SSH_HOST=$(shell_quote "$SSH_HOST") R6C_SSH_PORT=$(shell_quote "$SSH_PORT") R6C_ANDROID_SERIAL=$(shell_quote "$serial") R6C_SCRCPY_PORT=$(shell_quote "$SCRCPY_PORT") R6C_SCRCPY_VERBOSITY=debug R6C_SCRCPY_WINDOW_TITLE='R6C Docked scrcpy' R6C_SCRCPY_BORDERLESS=1 R6C_SCRCPY_WINDOW_X=$(shell_quote "$window_x") R6C_SCRCPY_WINDOW_Y=$(shell_quote "$window_y") R6C_SCRCPY_WINDOW_WIDTH=$(shell_quote "$window_w") R6C_SCRCPY_WINDOW_HEIGHT=$(shell_quote "$window_h") $(shell_quote "$SCRCPY_SCRIPT")"
    fi
  fi
  scrcpy_cmd="$scrcpy_cmd >>$(shell_quote "$SCRCPY_LOG") 2>&1"
  nohup /bin/zsh -lc "$scrcpy_cmd" >/dev/null 2>&1 &
  echo "$!" > "$SCRCPY_PID_FILE"
  sleep 2
  scrcpy_status
  tail -c 2000 "$SCRCPY_LOG" 2>/dev/null || true
}

cmd_stop_scrcpy() {
  stop_scrcpy_processes
  echo "OK stopped scrcpy"
}

cmd_dock_scrcpy() {
  x="${1:-}"
  y="${2:-}"
  w="${3:-}"
  h="${4:-}"
  [ -n "$x" ] && [ -n "$y" ] && [ -n "$w" ] && [ -n "$h" ] || {
    echo "ERROR missing dock geometry" >&2
    exit 2
  }
  osascript - "$x" "$y" "$w" "$h" <<'APPLESCRIPT'
on run argv
  set dockX to (item 1 of argv) as integer
  set dockY to (item 2 of argv) as integer
  set dockW to (item 3 of argv) as integer
  set dockH to (item 4 of argv) as integer
  tell application "System Events"
    set targetProcess to missing value
    repeat with p in processes
      try
        if (name of p is "scrcpy") then
          set targetProcess to p
          exit repeat
        end if
      end try
    end repeat
    if targetProcess is missing value then error "scrcpy process not found"
    tell targetProcess
      if (count of windows) is 0 then error "scrcpy window not found"
      set position of window 1 to {dockX, dockY}
      set size of window 1 to {dockW, dockH}
    end tell
  end tell
end run
APPLESCRIPT
  echo "OK docked scrcpy to ${x},${y} ${w}x${h}"
}

cmd_authorize() {
  if is_local_connection; then
    "$ADB_BIN" start-server >/dev/null
    echo "OK local ADB is ready; approve the USB debugging prompt on the phone if shown"
  else
    SSH_TIMEOUT=90 ssh_r6c '/root/r6c-scrcpy/authorize-adb-aoa.sh 2>&1'
  fi
}

local_sim_switch_script() {
  for path in "$BASE_DIR/switch-euicc.sh" "$BASE_DIR/Resources/switch-euicc.sh" "$BASE_DIR/remote/switch-euicc.sh"; do
    [ -x "$path" ] && { printf '%s\n' "$path"; return 0; }
  done
  echo "ERROR local eSIM helper is not bundled" >&2
  return 1
}

run_sim_switch() {
  serial="$1"
  shift
  if is_local_connection; then
    script="$(local_sim_switch_script)"
    dex="${EASYEUICC_DIRECT_CLI_REMOTE_DEX:-}"
    if [ -z "$dex" ]; then
      for candidate in "$BASE_DIR/euicc-app-process-cli.dex" "$BASE_DIR/Resources/euicc-app-process-cli.dex" "$BASE_DIR/android/easyeuicc-app-process-cli/build/euicc-app-process-cli.dex"; do
        [ -f "$candidate" ] && { dex="$candidate"; break; }
      done
    fi
    R6C_ANDROID_SERIAL="$serial" ADB="$ADB_BIN" EASYEUICC_DIRECT_CLI_REMOTE_DEX="$dex" "$script" "$@"
    return
  fi
  command="R6C_ANDROID_SERIAL=$(shell_quote "$serial") /root/r6c-sim-switch/switch-euicc.sh"
  for argument in "$@"; do
    command="$command $(shell_quote "$argument")"
  done
  android_host_shell "$command 2>&1"
}

cmd_profiles() {
  serial="$(require_serial)"
  SSH_TIMEOUT=180 run_sim_switch "$serial" status
}

cmd_profiles_json() {
  serial="$(require_serial)"
  SSH_TIMEOUT=180 run_sim_switch "$serial" list-json
}

cmd_switch() {
  target="${1:-}"
  [ -n "$target" ] || {
    echo "ERROR missing profile target" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=240 run_sim_switch "$serial" switch "$target"
}

cmd_switch_exact() {
  name="${1:-}"
  provider="${2:-}"
  [ -n "$name" ] || {
    echo "ERROR missing profile name" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=240 run_sim_switch "$serial" switch-exact "$name" "$provider"
}

cmd_switch_iccid() {
  iccid="${1:-}"
  [ -n "$iccid" ] || {
    echo "ERROR missing profile ICCID" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=240 run_sim_switch "$serial" switch-iccid "$iccid"
}

cmd_download_parse() {
  activation="${1:-}"
  [ -n "$activation" ] || {
    echo "ERROR missing activation code" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=30 run_sim_switch "$serial" download-parse "$activation"
}

cmd_download_dry_run() {
  activation="${1:-}"
  [ -n "$activation" ] || {
    echo "ERROR missing activation code" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=30 run_sim_switch "$serial" download-dry-run "$activation"
}

cmd_download() {
  activation="${1:-}"
  confirmation="${2:-}"
  [ -n "$activation" ] || {
    echo "ERROR missing activation code" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=300 run_sim_switch "$serial" download "$activation" "$confirmation"
}

cmd_web_open() {
  url="$(read_web_url)"
  [ -n "$url" ] || {
    echo "ERROR web control URL not found" >&2
    exit 2
  }
  open "$url"
  echo "OK opened web control"
}

cmd_web_start() {
  is_local_connection && { echo "ERROR web control is only available through an r6c remote" >&2; exit 2; }
  SSH_TIMEOUT=25 ssh_r6c '/root/r6c-android-control/start.sh 2>&1'
}

cmd_display() {
  mode="${1:-status}"
  serial="$(require_serial)"
  SSH_TIMEOUT=25 run_sim_switch "$serial" display "$mode"
}

case "${1:-status}" in
  status) cmd_status ;;
  phone-info) cmd_phone_info ;;
  messages) shift; cmd_messages "${1:-20}" ;;
  net) shift; cmd_net "${1:-}" "${2:-}" ;;
  shell) shift; cmd_shell "$@" ;;
  kali-shell) shift; cmd_kali_shell "$@" ;;
  adb-status) adb_status ;;
  devices) cmd_devices ;;
  profiles) cmd_profiles ;;
  profiles-json) cmd_profiles_json ;;
  screen-capture) shift; cmd_capture_screen "${1:-}" ;;
  start-stream) shift; cmd_start_stream "${1:-}" ;;
  h264-stream) cmd_h264_stream ;;
  stop-h264-stream) cmd_stop_h264_stream ;;
  scrcpy-control-stream) cmd_scrcpy_control_stream ;;
  scrcpy-embedded-stream) cmd_scrcpy_embedded_stream ;;
  stop-scrcpy-embedded-stream) cmd_stop_scrcpy_embedded_stream ;;
  stop-stream) cmd_stop_stream ;;
  stop-input) cmd_stop_input ;;
  stop-input-all) cmd_stop_all_input ;;
  tap) shift; cmd_tap "${1:-}" "${2:-}" ;;
  swipe) shift; cmd_swipe "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-250}" ;;
  keyevent) shift; cmd_keyevent "${1:-}" ;;
  stayon) shift; cmd_stayon "${1:-true}" ;;
  text) shift; cmd_text "${1:-}" ;;
  start-scrcpy) shift; cmd_start_scrcpy "$@" ;;
  stop-scrcpy) cmd_stop_scrcpy ;;
  dock-scrcpy) shift; cmd_dock_scrcpy "$@" ;;
  authorize) cmd_authorize ;;
  switch) shift; cmd_switch "${1:-}" ;;
  switch-exact) shift; cmd_switch_exact "${1:-}" "${2:-}" ;;
  switch-iccid) shift; cmd_switch_iccid "${1:-}" ;;
  download-parse) shift; cmd_download_parse "${1:-}" ;;
  download-dry-run) shift; cmd_download_dry_run "${1:-}" ;;
  download) shift; cmd_download "${1:-}" "${2:-}" ;;
  open-web) cmd_web_open ;;
  start-web) cmd_web_start ;;
  display) shift; cmd_display "${1:-status}" ;;
  *)
    echo "Usage: $0 status|phone-info|messages [limit]|net <mobile|wifi|bluetooth> <on|off>|shell <command>|kali-shell <command>|adb-status|devices|profiles|profiles-json|screen-capture [path]|start-stream [frame.jpg]|h264-stream|stop-h264-stream|scrcpy-control-stream|scrcpy-embedded-stream|stop-scrcpy-embedded-stream|stop-stream|stop-input|stop-input-all|tap <x y>|swipe <x1 y1 x2 y2 [ms]>|keyevent <name>|stayon <true|false>|text <value>|start-scrcpy [x y w h]|stop-scrcpy|dock-scrcpy <x y w h>|authorize|switch <target>|switch-exact <name> <provider>|switch-iccid <iccid>|download-parse <LPA-or-url>|download-dry-run <LPA-or-url>|download <LPA-or-url> [confirmation-code]|open-web|start-web|display <fast|reset|status>" >&2
    exit 2
    ;;
esac
