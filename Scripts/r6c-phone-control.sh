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
  wait "$pid"
  rc="$?"
  cat "$tmp"
  rm -f "$tmp"
  return "$rc"
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
    SSH_TIMEOUT=12 ssh_r6c 'ADB_VENDOR_KEYS=/root/.android adb devices -l 2>&1' |
      awk -v serial="$serial" '
        $1 == serial && / device / { found="connected"; detail=$0 }
        $1 == serial && / unauthorized/ { found="unauthorized"; detail=$0 }
        END {
          if (found == "") found="missing";
          print "adb=" found;
          if (detail != "") print "adb_detail=" detail;
        }'
  else
    SSH_TIMEOUT=12 ssh_r6c 'ADB_VENDOR_KEYS=/root/.android adb devices -l 2>&1' |
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
  SSH_TIMEOUT=12 ssh_r6c 'ADB_VENDOR_KEYS=/root/.android adb devices -l 2>&1' |
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
  SSH_TIMEOUT=12 ssh_r6c 'ADB_VENDOR_KEYS=/root/.android adb devices 2>&1' |
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
  SSH_TIMEOUT=3 ssh_r6c "serial=$(shell_quote "$serial"); fifo=$(shell_quote "$fifo"); pidfile=$(shell_quote "$pidfile"); log=$(shell_quote "$log"); if [ ! -p \"\$fifo\" ] || ! kill -0 \"\$(cat \"\$pidfile\" 2>/dev/null)\" 2>/dev/null; then rm -f \"\$fifo\"; mkfifo \"\$fifo\"; (while :; do cat \"\$fifo\"; done | ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell >\"\$log\" 2>&1) & echo \$! > \"\$pidfile\"; fi; printf '%s\n' $(shell_quote "$command") > \"\$fifo\"" >/dev/null
}

stop_input_relay() {
  serial="$1"
  fifo="$(input_fifo "$serial")"
  pidfile="$(input_pid_file "$serial")"
  SSH_TIMEOUT=3 ssh_r6c "fifo=$(shell_quote "$fifo"); pidfile=$(shell_quote "$pidfile"); if [ -s \"\$pidfile\" ]; then kill \"\$(cat \"\$pidfile\")\" >/dev/null 2>&1 || true; fi; rm -f \"\$fifo\" \"\$pidfile\"" >/dev/null
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
  if ssh_cmd "$SSH_HOST" "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") exec-out screencap -p" >"$tmp"; then
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

  remote_cmd="ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") exec-out screenrecord --output-format=h264 --time-limit ${R6C_STREAM_SEGMENT_SECONDS:-2} --bit-rate ${R6C_STREAM_BITRATE:-4M} -"
  stream_cmd="while :; do ssh -i $(shell_quote "$SSH_KEY") -p $(shell_quote "$SSH_PORT") -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o ControlMaster=auto -o ControlPersist=300 -S $(shell_quote "$SSH_CONTROL_PATH") $(shell_quote "$SSH_HOST") $(shell_quote "$remote_cmd") | ffmpeg -y -hide_banner -loglevel error -f h264 -i pipe:0 -vf fps=${R6C_STREAM_FPS:-30},format=yuvj420p -threads 1 -q:v ${R6C_STREAM_JPEG_QUALITY:-4} -update 1 -atomic_writing 1 $(shell_quote "$frame"); sleep 0.05; done"
  nohup /bin/zsh -lc "$stream_cmd" >>"$STREAM_LOG" 2>&1 &
  echo "$!" > "$STREAM_PID_FILE"
  echo "stream=starting"
  echo "frame=$frame"
}

cmd_h264_stream() {
  serial="$(require_serial)"
  segment="${R6C_H264_STREAM_SEGMENT_SECONDS:-120}"
  bitrate="${R6C_H264_STREAM_BITRATE:-8M}"
  child=""
  echo "$$" > "$H264_STREAM_PID_FILE"
  cleanup_h264_stream() {
    [ -n "$child" ] && kill_process_tree "$child" >/dev/null 2>&1 || true
    rm -f "$H264_STREAM_PID_FILE"
  }
  trap 'cleanup_h264_stream; exit 0' INT TERM
  trap 'cleanup_h264_stream' EXIT

  while :; do
    ssh_cmd "$SSH_HOST" "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") exec-out screenrecord --output-format=h264 --time-limit $(shell_quote "$segment") --bit-rate $(shell_quote "$bitrate") -" &
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
  SSH_TIMEOUT=5 ssh_r6c 'for pidfile in /tmp/r6c-input-*.pid; do [ -e "$pidfile" ] || continue; kill "$(cat "$pidfile")" >/dev/null 2>&1 || true; done; rm -f /tmp/r6c-input-*.fifo /tmp/r6c-input-*.pid' >/dev/null || true
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
  scp -i "$SSH_KEY" -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$server" "$SSH_HOST:$remote_server" >/dev/null
  ssh_cmd "$SSH_HOST" "set -eu; serial=$(shell_quote "$serial"); port=$(shell_quote "$SCRCPY_CONTROL_PORT"); scid=$(shell_quote "$SCRCPY_CONTROL_SCID"); remote_server=$(shell_quote "$remote_server"); device_server=$(shell_quote "$device_server"); log=/tmp/r6c-scrcpy-control-\$serial.log; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" push \"\$remote_server\" \"\$device_server\" >/dev/null 2>&1; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward --remove tcp:\"\$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward tcp:\"\$port\" localabstract:scrcpy_\"\$scid\" >/dev/null; (ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell CLASSPATH=\"\$device_server\" app_process / com.genymobile.scrcpy.Server 4.0 scid=\"\$scid\" log_level=warn video=false audio=false control=true tunnel_forward=true cleanup=false power_on=true clipboard_autosync=false send_device_meta=false send_dummy_byte=false >\"\$log\" 2>&1 &) ; sleep 1; exec nc 127.0.0.1 \"\$port\""
}

cmd_scrcpy_embedded_stream() {
  serial="$(require_serial)"
  server="$(scrcpy_server_path)"
  remote_server="/tmp/r6c-phone-control-scrcpy-server"
  device_server="/data/local/tmp/scrcpy-server.jar"
  echo "$$" > "$SCRCPY_EMBEDDED_PID_FILE"
  trap 'rm -f "$SCRCPY_EMBEDDED_PID_FILE"' EXIT
  scp -i "$SSH_KEY" -P "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$server" "$SSH_HOST:$remote_server" >/dev/null
  ssh_cmd "$SSH_HOST" "set -eu; serial=$(shell_quote "$serial"); port=$(shell_quote "$SCRCPY_EMBEDDED_PORT"); scid=$(shell_quote "$SCRCPY_EMBEDDED_SCID"); remote_server=$(shell_quote "$remote_server"); device_server=$(shell_quote "$device_server"); log=/tmp/r6c-scrcpy-embedded-\$serial.log; pkill -f \"nc 127.0.0.1 \$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" push \"\$remote_server\" \"\$device_server\" >/dev/null 2>&1; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward --remove tcp:\"\$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" forward tcp:\"\$port\" localabstract:scrcpy_\"\$scid\" >/dev/null; (ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell CLASSPATH=\"\$device_server\" app_process / com.genymobile.scrcpy.Server 4.0 scid=\"\$scid\" log_level=warn audio=false control=true tunnel_forward=true cleanup=false power_on=true clipboard_autosync=false raw_stream=true video_bit_rate=8000000 max_fps=60 >\"\$log\" 2>&1 &) ; sleep 1; tail -f /dev/null | nc 127.0.0.1 \"\$port\" & video_pid=\$!; sleep 1; trap 'kill \"\$video_pid\" >/dev/null 2>&1 || true; pkill -f \"nc 127.0.0.1 \$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s \"\$serial\" shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true; wait \"\$video_pid\" >/dev/null 2>&1 || true' INT TERM EXIT; nc 127.0.0.1 \"\$port\" >/dev/null || true"
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
    SSH_TIMEOUT=5 ssh_r6c "port=$(shell_quote "$SCRCPY_EMBEDDED_PORT"); scid=$(shell_quote "$SCRCPY_EMBEDDED_SCID"); pkill -f \"nc 127.0.0.1 \$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") forward --remove tcp:\"\$port\" >/dev/null 2>&1 || true; ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell pkill -f \"scrcpy.Server.*scid=\$scid\" >/dev/null 2>&1 || true" >/dev/null || true
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
    SSH_TIMEOUT=8 ssh_r6c "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input tap $x $y >/dev/null 2>&1"
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
    SSH_TIMEOUT=8 ssh_r6c "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input swipe $x1 $y1 $x2 $y2 $ms >/dev/null 2>&1"
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
    SSH_TIMEOUT=8 ssh_r6c "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input keyevent $(shell_quote "$key") >/dev/null 2>&1"
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
    SSH_TIMEOUT=8 ssh_r6c "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell svc power stayon $(shell_quote "$mode") >/dev/null 2>&1"
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
    SSH_TIMEOUT=8 ssh_r6c "ADB_VENDOR_KEYS=/root/.android adb -s $(shell_quote "$serial") shell input text $(shell_quote "$arg") >/dev/null 2>&1"
  echo "OK text"
}

cmd_status() {
  adb_status || {
    echo "adb=error"
  }
  scrcpy_status
  if web_url_available; then
    echo "web=available"
  else
    echo "web=missing"
  fi
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
  require_scrcpy_script
  serial="$(require_serial)"
  window_x="${1:-}"
  window_y="${2:-}"
  window_w="${3:-}"
  window_h="${4:-}"
  stop_scrcpy_processes
  : > "$SCRCPY_LOG"
  scrcpy_cmd="R6C_SCRCPY_DIR=$(shell_quote "$SCRCPY_DIR") R6C_SSH_KEY=$(shell_quote "$SSH_KEY") R6C_SSH_HOST=$(shell_quote "$SSH_HOST") R6C_SSH_PORT=$(shell_quote "$SSH_PORT") R6C_ANDROID_SERIAL=$(shell_quote "$serial") R6C_SCRCPY_PORT=$(shell_quote "$SCRCPY_PORT") R6C_SCRCPY_VERBOSITY=debug $(shell_quote "$SCRCPY_SCRIPT") >>$(shell_quote "$SCRCPY_LOG") 2>&1"
  if [ -n "$window_x" ] && [ -n "$window_y" ] && [ -n "$window_w" ] && [ -n "$window_h" ]; then
    scrcpy_cmd="R6C_SCRCPY_DIR=$(shell_quote "$SCRCPY_DIR") R6C_SSH_KEY=$(shell_quote "$SSH_KEY") R6C_SSH_HOST=$(shell_quote "$SSH_HOST") R6C_SSH_PORT=$(shell_quote "$SSH_PORT") R6C_ANDROID_SERIAL=$(shell_quote "$serial") R6C_SCRCPY_PORT=$(shell_quote "$SCRCPY_PORT") R6C_SCRCPY_VERBOSITY=debug R6C_SCRCPY_WINDOW_TITLE='R6C Docked scrcpy' R6C_SCRCPY_BORDERLESS=1 R6C_SCRCPY_WINDOW_X=$(shell_quote "$window_x") R6C_SCRCPY_WINDOW_Y=$(shell_quote "$window_y") R6C_SCRCPY_WINDOW_WIDTH=$(shell_quote "$window_w") R6C_SCRCPY_WINDOW_HEIGHT=$(shell_quote "$window_h") $(shell_quote "$SCRCPY_SCRIPT") >>$(shell_quote "$SCRCPY_LOG") 2>&1"
  fi
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
  SSH_TIMEOUT=90 ssh_r6c '/root/r6c-scrcpy/authorize-adb-aoa.sh 2>&1'
}

cmd_profiles() {
  serial="$(require_serial)"
  SSH_TIMEOUT=180 ssh_r6c "R6C_ANDROID_SERIAL=$(shell_quote "$serial") /root/r6c-sim-switch/switch-euicc.sh status 2>&1"
}

cmd_switch() {
  target="${1:-}"
  [ -n "$target" ] || {
    echo "ERROR missing profile target" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=240 ssh_r6c "R6C_ANDROID_SERIAL=$(shell_quote "$serial") /root/r6c-sim-switch/switch-euicc.sh switch $(shell_quote "$target") 2>&1"
}

cmd_switch_exact() {
  name="${1:-}"
  provider="${2:-}"
  [ -n "$name" ] || {
    echo "ERROR missing profile name" >&2
    exit 2
  }
  serial="$(require_serial)"
  SSH_TIMEOUT=240 ssh_r6c "R6C_ANDROID_SERIAL=$(shell_quote "$serial") /root/r6c-sim-switch/switch-euicc.sh switch-exact $(shell_quote "$name") $(shell_quote "$provider") 2>&1"
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
  SSH_TIMEOUT=25 ssh_r6c '/root/r6c-android-control/start.sh 2>&1'
}

cmd_display() {
  mode="${1:-status}"
  serial="$(require_serial)"
  SSH_TIMEOUT=25 ssh_r6c "R6C_ANDROID_SERIAL=$(shell_quote "$serial") /root/r6c-sim-switch/switch-euicc.sh display $(shell_quote "$mode") 2>&1"
}

case "${1:-status}" in
  status) cmd_status ;;
  adb-status) adb_status ;;
  devices) cmd_devices ;;
  profiles) cmd_profiles ;;
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
  open-web) cmd_web_open ;;
  start-web) cmd_web_start ;;
  display) shift; cmd_display "${1:-status}" ;;
  *)
    echo "Usage: $0 status|adb-status|devices|profiles|screen-capture [path]|start-stream [frame.jpg]|h264-stream|stop-h264-stream|scrcpy-control-stream|scrcpy-embedded-stream|stop-scrcpy-embedded-stream|stop-stream|stop-input|stop-input-all|tap <x y>|swipe <x1 y1 x2 y2 [ms]>|keyevent <name>|stayon <true|false>|text <value>|start-scrcpy [x y w h]|stop-scrcpy|dock-scrcpy <x y w h>|authorize|switch <target>|switch-exact <name> <provider>|open-web|start-web|display <fast|reset|status>" >&2
    exit 2
    ;;
esac
