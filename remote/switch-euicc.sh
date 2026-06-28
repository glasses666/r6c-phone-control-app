#!/bin/sh
set -eu

ENV_FILE="${R6C_SIM_SWITCH_ENV:-/root/.r6c-sim-switch.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

ADB="${ADB:-/usr/bin/adb}"
export ADB_VENDOR_KEYS="${ADB_VENDOR_KEYS:-/root/.android}"
SERIAL="${R6C_ANDROID_SERIAL:-${ANDROID_SERIAL:-}}"
PACKAGE="${EASYEUICC_PACKAGE:-im.angry.easyeuicc}"
ACTIVITY="${EASYEUICC_ACTIVITY:-im.angry.openeuicc.ui.UnprivilegedMainActivity}"
XML_FILE="${XML_FILE:-/tmp/r6c-euicc-window.$$.xml}"
PROFILES_FILE="${PROFILES_FILE:-/tmp/r6c-euicc-profiles.$$.tsv}"
SCREEN_FILE="${SCREEN_FILE:-/tmp/r6c-euicc-screen.png}"

usage() {
  cat <<'EOF'
Usage:
  switch-euicc.sh list
  switch-euicc.sh status
  switch-euicc.sh switch <profile-or-provider>
  switch-euicc.sh switch-exact <profile-name> [provider]
  switch-euicc.sh display fast
  switch-euicc.sh display reset

Environment:
  R6C_ANDROID_PIN       Required for unlocking when the device is locked.
  R6C_ANDROID_SERIAL    Optional adb serial; auto-detected when omitted.
  R6C_SIM_SWITCH_ENV    Optional env file path; default /root/.r6c-sim-switch.env.
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

wake_unlock() {
  adb_shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb_shell svc power stayon true >/dev/null 2>&1 || true
  sleep 1
  adb_shell input swipe 540 2050 540 450 500 >/dev/null 2>&1 || true
  sleep 1
  if [ -n "${R6C_ANDROID_PIN:-}" ]; then
    adb_shell input text "$R6C_ANDROID_PIN" >/dev/null 2>&1 || true
    adb_shell input keyevent ENTER >/dev/null 2>&1 || true
    sleep 2
  fi
}

open_easyeuicc() {
  adb_shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
  adb_shell am start -n "$PACKAGE/$ACTIVITY" >/dev/null 2>&1 || {
    echo "ERROR failed to start EasyEUICC activity" >&2
    exit 1
  }
  sleep 2
}

dump_ui() {
  adb_shell uiautomator dump /sdcard/window.xml >/dev/null 2>&1 || return 1
  "$ADB" -s "$SERIAL" shell cat /sdcard/window.xml > "$XML_FILE"
}

extract_profiles() {
  [ -s "$XML_FILE" ] || return 1
  lua - "$XML_FILE" > "$PROFILES_FILE" <<'LUA'
local xml_path = arg[1]
local f = assert(io.open(xml_path, "r"))
local xml = f:read("*a")
f:close()

local function attr(node, key)
  return node:match(key .. '="([^"]*)"') or ""
end

local function decode(s)
  return (s or "")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&amp;", "&")
end

local profiles = {}
local current = nil

for node in xml:gmatch("<node%s[^>]->") do
  local rid = attr(node, "resource%-id")
  local text = decode(attr(node, "text"))
  local bounds = attr(node, "bounds")

  if rid:match(":id/name$") then
    current = { name = text, bounds = bounds }
    table.insert(profiles, current)
  elseif current and rid:match(":id/profile_menu$") and not current.menu then
    current.menu = bounds
  elseif current and rid:match(":id/state$") and not current.state then
    current.state = text
  elseif current and rid:match(":id/provider$") and not current.provider then
    current.provider = text
  end
end

for _, p in ipairs(profiles) do
  print(table.concat({ p.name or "", p.state or "", p.provider or "", p.menu or "" }, "\t"))
end
LUA
}

refresh_profiles() {
  i=0
  while [ "$i" -lt 3 ]; do
    if dump_ui && extract_profiles; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "ERROR failed to dump Android UI" >&2
  exit 1
}

ensure_open() {
  need_device
  wake_unlock
  open_easyeuicc
}

print_profiles() {
  while IFS="$(printf '\t')" read -r name state provider menu; do
    [ -n "$name" ] || continue
    printf 'PROFILE name="%s" state="%s" provider="%s"\n' "$name" "$state" "$provider"
  done < "$PROFILES_FILE"
}

select_profile() {
  target="$1"
  lua - "$PROFILES_FILE" "$target" <<'LUA'
local file, target = arg[1], (arg[2] or ""):lower()
local f = assert(io.open(file, "r"))
for line in f:lines() do
  local name, state, provider, menu = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
  if name then
    local lname = name:lower()
    local lprovider = (provider or ""):lower()
    if lname == target or lprovider == target or lname:find(target, 1, true) or lprovider:find(target, 1, true) then
      print(line)
      return
    end
  end
end
LUA
}

select_profile_exact() {
  target_name="$1"
  target_provider="${2:-}"
  lua - "$PROFILES_FILE" "$target_name" "$target_provider" <<'LUA'
local file, target_name, target_provider = arg[1], arg[2] or "", arg[3] or ""
local f = assert(io.open(file, "r"))
for line in f:lines() do
  local name, state, provider, menu = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
  if name then
    provider = provider or ""
    if name == target_name and (target_provider == "" or provider == target_provider) then
      print(line)
      return
    end
  end
end
LUA
}

profile_match_count() {
  mode="$1"
  target="$2"
  target_provider="${3:-}"
  lua - "$PROFILES_FILE" "$mode" "$target" "$target_provider" <<'LUA'
local file, mode, target, target_provider = arg[1], arg[2] or "", arg[3] or "", arg[4] or ""
local f = assert(io.open(file, "r"))
local count = 0
local lower_target = target:lower()

for line in f:lines() do
  local name, state, provider, menu = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
  if name then
    provider = provider or ""
    local matched = false
    if mode == "exact" then
      matched = name == target and (target_provider == "" or provider == target_provider)
    else
      local lname = name:lower()
      local lprovider = provider:lower()
      matched = lname == lower_target or lprovider == lower_target or
        lname:find(lower_target, 1, true) ~= nil or lprovider:find(lower_target, 1, true) ~= nil
    end
    if matched then count = count + 1 end
  end
end

print(count)
LUA
}

field() {
  printf '%s\n' "$1" | awk -F "$(printf '\t')" -v n="$2" '{ print $n }'
}

center_of_bounds() {
  cleaned="$(printf '%s' "$1" | sed 's/]\[/,/g' | tr -d '[]' | tr ',' ' ')"
  set -- $cleaned
  [ "$#" -eq 4 ] || return 1
  printf '%s %s\n' "$((($1 + $3) / 2))" "$((($2 + $4) / 2))"
}

bounds_numbers() {
  cleaned="$(printf '%s' "$1" | sed 's/]\[/,/g' | tr -d '[]' | tr ',' ' ')"
  set -- $cleaned
  [ "$#" -eq 4 ] || return 1
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4"
}

tap_bounds() {
  point="$(center_of_bounds "$1")" || return 1
  set -- $point
  adb_shell input tap "$1" "$2" >/dev/null 2>&1
}

dump_screen() {
  "$ADB" -s "$SERIAL" exec-out screencap -p > "$SCREEN_FILE" 2>/dev/null || true
}

find_text_bounds() {
  [ -s "$XML_FILE" ] || return 1
  text="$1"
  lua - "$XML_FILE" "$text" <<'LUA'
local xml_path, wanted = arg[1], arg[2]
local f = assert(io.open(xml_path, "r"))
local xml = f:read("*a")
f:close()

local function attr(node, key)
  return node:match(key .. '="([^"]*)"') or ""
end

local function decode(s)
  return (s or "")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&amp;", "&")
end

for node in xml:gmatch("<node%s[^>]->") do
  if decode(attr(node, "text")) == wanted or decode(attr(node, "content%-desc")) == wanted then
    local bounds = attr(node, "bounds")
    if bounds ~= "" then print(bounds); return end
  end
end
LUA
}

tap_first_present_text() {
  for label in "$@"; do
    bounds="$(find_text_bounds "$label" || true)"
    if [ -n "$bounds" ]; then
      tap_bounds "$bounds" || true
      return 0
    fi
  done
  return 1
}

screen_width() {
  adb_shell wm size 2>/dev/null |
    sed -n 's/.*Physical size: \([0-9][0-9]*\)x.*/\1/p; s/.*Override size: \([0-9][0-9]*\)x.*/\1/p' |
    tail -n 1
}

screen_size() {
  adb_shell wm size 2>/dev/null |
    sed -n 's/.*Physical size: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p; s/.*Override size: \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' |
    tail -n 1
}

profile_list_bounds() {
  [ -s "$XML_FILE" ] || return 1
  lua - "$XML_FILE" <<'LUA'
local xml_path = arg[1]
local f = assert(io.open(xml_path, "r"))
local xml = f:read("*a")
f:close()
local fallback = ""
for node in xml:gmatch("<node%s[^>]->") do
  local rid = node:match('resource%-id="([^"]*)"') or ""
  local scrollable = node:match('scrollable="([^"]*)"') or ""
  local bounds = node:match('bounds="([^"]*)"') or ""
  if rid:match(":id/profile_list$") and bounds ~= "" then print(bounds); return end
  if fallback == "" and scrollable == "true" and bounds ~= "" then fallback = bounds end
end
if fallback ~= "" then print(fallback) end
LUA
}

swipe_profiles() {
  direction="$1"
  bounds="$(profile_list_bounds || true)"
  if [ -n "$bounds" ]; then
    set -- $(bounds_numbers "$bounds")
    sx=$((($1 + $3) / 2))
    top="$2"
    bottom="$4"
  else
    set -- $(screen_size)
    sx=$((${1:-1080} / 2))
    top=$((${2:-2200} / 4))
    bottom=$(((${2:-2200} * 3) / 4))
  fi
  sy1=$((top + ((bottom - top) / 4)))
  sy2=$((top + (((bottom - top) * 3) / 4)))
  if [ "$direction" = "up" ]; then
    adb_shell input swipe "$sx" "$sy2" "$sx" "$sy1" 350 >/dev/null 2>&1
  else
    adb_shell input swipe "$sx" "$sy1" "$sx" "$sy2" 350 >/dev/null 2>&1
  fi
}

scroll_profiles_to_top() {
  i=0
  while [ "$i" -lt 2 ]; do
    swipe_profiles down || true
    i=$((i + 1))
  done
}

append_unique_profiles() {
  out="$1"
  touch "$out"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -Fqx "$line" "$out" 2>/dev/null || printf '%s\n' "$line" >> "$out"
  done < "$PROFILES_FILE"
}

collect_profiles_all() {
  out="${PROFILES_FILE}.all"
  : > "$out"
  scroll_profiles_to_top
  stagnant=0
  i=0
  limit="${R6C_SIM_SCROLL_LIMIT:-120}"
  while [ "$i" -lt "$limit" ]; do
    refresh_profiles
    before="$(wc -l < "$out" | tr -d ' ')"
    append_unique_profiles "$out"
    after="$(wc -l < "$out" | tr -d ' ')"
    if [ "$after" = "$before" ]; then
      stagnant=$((stagnant + 1))
    else
      stagnant=0
    fi
    [ "$stagnant" -ge 2 ] && break
    swipe_profiles up || break
    i=$((i + 1))
  done
  mv "$out" "$PROFILES_FILE"
}

find_profile_with_scroll() {
  target="$1"
  scroll_profiles_to_top
  i=0
  limit="${R6C_SIM_SCROLL_LIMIT:-120}"
  while [ "$i" -lt "$limit" ]; do
    refresh_profiles
    line="$(select_profile "$target" || true)"
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    swipe_profiles up || break
    i=$((i + 1))
  done
  return 1
}

find_profile_exact_with_scroll() {
  target_name="$1"
  target_provider="${2:-}"
  scroll_profiles_to_top
  i=0
  limit="${R6C_SIM_SCROLL_LIMIT:-120}"
  while [ "$i" -lt "$limit" ]; do
    refresh_profiles
    line="$(select_profile_exact "$target_name" "$target_provider" || true)"
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    swipe_profiles up || break
    i=$((i + 1))
  done
  return 1
}

tap_profile_menu_visual() {
  name="$1"
  bounds="$(find_text_bounds "$name" || true)"
  [ -n "$bounds" ] || return 1
  point="$(center_of_bounds "$bounds")" || return 1
  set -- $point
  width="$(screen_width)"
  [ -n "$width" ] || width=1080
  x=$((width - 92))
  adb_shell input tap "$x" "$2" >/dev/null 2>&1
}

tap_enable_item() {
  tap_first_present_text "启用" "Enable" "ENABLE" "激活" "使用" "确定" "确认"
}

ensure_open_and_listed() {
  ensure_open
  refresh_profiles
}

select_for_mode() {
  mode="$1"
  arg1="$2"
  arg2="${3:-}"
  if [ "$mode" = "exact" ]; then
    select_profile_exact "$arg1" "$arg2"
  else
    select_profile "$arg1"
  fi
}

switch_selected_profile() {
  line="$1"
  mode="$2"
  arg1="$3"
  arg2="${4:-}"

  name="$(field "$line" 1)"
  state="$(field "$line" 2)"
  menu="$(field "$line" 4)"

  case "$state" in
    *已启用*|*Enabled*|*enabled*)
      printf 'OK already-enabled profile="%s"\n' "$name"
      print_profiles
      return 0
      ;;
  esac

  if [ -n "$menu" ]; then
    tap_bounds "$menu" || tap_profile_menu_visual "$name" || {
      dump_screen
      echo "ERROR failed to tap profile menu for: $name" >&2
      echo "SCREEN $SCREEN_FILE" >&2
      exit 1
    }
  else
    tap_profile_menu_visual "$name" || {
      dump_screen
      echo "ERROR menu bounds missing for profile: $name" >&2
      echo "SCREEN $SCREEN_FILE" >&2
      exit 1
    }
  fi
  sleep 1
  dump_ui || true
  enable_bounds="$(find_text_bounds "启用" || true)"
  if [ -n "$enable_bounds" ]; then
    tap_bounds "$enable_bounds" || {
      dump_screen
      echo "ERROR failed to tap Enable for: $name" >&2
      echo "SCREEN $SCREEN_FILE" >&2
      exit 1
    }
  elif ! tap_enable_item; then
    dump_screen
    echo "ERROR Enable menu item not found for: $name" >&2
    echo "SCREEN $SCREEN_FILE" >&2
    exit 1
  fi

  i=0
  while [ "$i" -lt 20 ]; do
    sleep 2
    refresh_profiles
    line="$(select_for_mode "$mode" "$arg1" "$arg2" || true)"
    state="$(field "$line" 2)"
    case "$state" in
      *已启用*|*Enabled*|*enabled*)
        printf 'OK switched profile="%s"\n' "$name"
        print_profiles
        return 0
        ;;
    esac

    dump_ui || true
    tap_first_present_text "确定" "确认" "允许" "OK" "Enable" "启用" >/dev/null 2>&1 || true
    i=$((i + 1))
  done

  dump_screen
  echo "ERROR switch did not verify within timeout" >&2
  echo "SCREEN $SCREEN_FILE" >&2
  print_profiles >&2
  exit 1
}

switch_profile() {
  target="$1"
  ensure_open
  collect_profiles_all
  matches="$(profile_match_count fuzzy "$target")"
  if [ "$matches" -gt 1 ]; then
    echo "ERROR ambiguous profile/provider target: $target matched $matches profiles" >&2
    print_profiles >&2
    exit 1
  fi
  if [ "$matches" -eq 0 ]; then
    echo "ERROR profile/provider not found: $target" >&2
    print_profiles >&2
    exit 1
  fi
  line="$(find_profile_with_scroll "$target" || true)"
  [ -n "$line" ] || {
    echo "ERROR profile/provider not found: $target" >&2
    collect_profiles_all
    print_profiles >&2
    exit 1
  }
  switch_selected_profile "$line" fuzzy "$target"
}

switch_profile_exact() {
  target_name="$1"
  target_provider="${2:-}"
  ensure_open
  collect_profiles_all
  matches="$(profile_match_count exact "$target_name" "$target_provider")"
  if [ "$matches" -gt 1 ]; then
    echo "ERROR ambiguous profile: name=$target_name provider=$target_provider matched $matches profiles" >&2
    print_profiles >&2
    exit 1
  fi
  if [ "$matches" -eq 0 ]; then
    echo "ERROR profile not found: name=$target_name provider=$target_provider" >&2
    print_profiles >&2
    exit 1
  fi
  line="$(find_profile_exact_with_scroll "$target_name" "$target_provider" || true)"
  [ -n "$line" ] || {
    echo "ERROR profile not found: name=$target_name provider=$target_provider" >&2
    collect_profiles_all
    print_profiles >&2
    exit 1
  }
  switch_selected_profile "$line" exact "$target_name" "$target_provider"
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
    ensure_open
    collect_profiles_all
    print_profiles
    ;;
  switch)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    switch_profile "$2"
    ;;
  switch-exact)
    [ -n "${2:-}" ] || {
      usage >&2
      exit 2
    }
    switch_profile_exact "$2" "${3:-}"
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
