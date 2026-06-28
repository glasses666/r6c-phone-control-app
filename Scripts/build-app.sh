#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_NAME="R6C Phone Control"
EXECUTABLE="R6CPhoneControl"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$PROJECT_DIR/.build/release/$EXECUTABLE" "$MACOS/$APP_NAME"
cp "$PROJECT_DIR/Scripts/r6c-phone-control.sh" "$RESOURCES/r6c-phone-control.sh"
cp "$PROJECT_DIR/Scripts/start-scrcpy-r6c.sh" "$RESOURCES/start-scrcpy-r6c.sh"
cp "$PROJECT_DIR/Scripts/adb-r6c.py" "$RESOURCES/adb-r6c.py"
for server in \
  /opt/homebrew/share/scrcpy/scrcpy-server \
  /usr/local/share/scrcpy/scrcpy-server \
  /opt/homebrew/Cellar/scrcpy/*/share/scrcpy/scrcpy-server \
  /usr/local/Cellar/scrcpy/*/share/scrcpy/scrcpy-server
do
  [ -f "$server" ] || continue
  cp "$server" "$RESOURCES/scrcpy-server"
  break
done
chmod +x "$MACOS/$APP_NAME" "$RESOURCES/r6c-phone-control.sh" "$RESOURCES/start-scrcpy-r6c.sh" "$RESOURCES/adb-r6c.py"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>R6C Phone Control</string>
  <key>CFBundleIdentifier</key>
  <string>local.dracoglasser.r6c-phone-control</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>R6C Phone Control</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "$APP_DIR"
