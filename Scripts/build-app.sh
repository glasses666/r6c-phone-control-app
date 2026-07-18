#!/bin/sh
set -eu

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_NAME="R6C Phone Control"
EXECUTABLE="R6CPhoneControl"
DIST_DIR="$PROJECT_DIR/dist"
FINAL_APP_DIR="$DIST_DIR/$APP_NAME.app"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/r6c-phone-control.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_DIR="$STAGING_ROOT/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

cd "$PROJECT_DIR"
DJI_HELPER="$PROJECT_DIR/.build/dji-at-helper"
LIBUSB_LIBDIR="$(pkg-config --variable=libdir libusb-1.0)"
cc -Wall -Wextra -Werror \
  "$PROJECT_DIR/Tools/dji-at-helper.c" \
  $(pkg-config --cflags --libs libusb-1.0) \
  -o "$DJI_HELPER"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"
cp "$PROJECT_DIR/.build/release/$EXECUTABLE" "$MACOS/$APP_NAME"
cp "$PROJECT_DIR/Scripts/r6c-phone-control.sh" "$RESOURCES/r6c-phone-control.sh"
cp "$PROJECT_DIR/Scripts/start-scrcpy-r6c.sh" "$RESOURCES/start-scrcpy-r6c.sh"
cp "$PROJECT_DIR/Scripts/adb-r6c.py" "$RESOURCES/adb-r6c.py"
cp "$PROJECT_DIR/Scripts/dji_sms_bark.py" "$RESOURCES/dji_sms_bark.py"
cp "$PROJECT_DIR/Resources/local.r6c.dji-sms-bark.plist" "$RESOURCES/local.r6c.dji-sms-bark.plist"
cp "$PROJECT_DIR/remote/switch-euicc.sh" "$RESOURCES/switch-euicc.sh"
cp "$PROJECT_DIR/android/easyeuicc-app-process-cli/build/euicc-app-process-cli.dex" "$RESOURCES/euicc-app-process-cli.dex"
cp "$DJI_HELPER" "$RESOURCES/dji-at-helper"
cp "$PROJECT_DIR/Resources/DJI_IG830_high_fidelity.usdz" "$RESOURCES/DJI_IG830_high_fidelity.usdz"
cp -R "$PROJECT_DIR/Vendor/lpac-dji" "$RESOURCES/lpac"
cp "$LIBUSB_LIBDIR/libusb-1.0.0.dylib" "$FRAMEWORKS/libusb-1.0.0.dylib"
chmod u+w "$FRAMEWORKS/libusb-1.0.0.dylib"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
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
LIBUSB_INSTALL_NAME="$(otool -L "$RESOURCES/dji-at-helper" | awk '/libusb-1.0.0.dylib/ { print $1; exit }')"
install_name_tool -change "$LIBUSB_INSTALL_NAME" "@loader_path/../Frameworks/libusb-1.0.0.dylib" "$RESOURCES/dji-at-helper"
LPAC_DJI_DRIVER="$RESOURCES/lpac/driver/driver_apdu_dji_usb.dylib"
LPAC_LIBUSB_INSTALL_NAME="$(otool -L "$LPAC_DJI_DRIVER" | awk '/libusb-1.0.0.dylib/ { print $1; exit }')"
install_name_tool -change "$LPAC_LIBUSB_INSTALL_NAME" "@loader_path/../../../Frameworks/libusb-1.0.0.dylib" "$LPAC_DJI_DRIVER"
chmod +x "$MACOS/$APP_NAME" "$RESOURCES/r6c-phone-control.sh" "$RESOURCES/start-scrcpy-r6c.sh" "$RESOURCES/adb-r6c.py" "$RESOURCES/dji_sms_bark.py" "$RESOURCES/switch-euicc.sh" "$RESOURCES/dji-at-helper" "$RESOURCES/lpac/lpac"

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>R6C Phone Control</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR"
codesign --force --sign - "$FRAMEWORKS/libusb-1.0.0.dylib"
codesign --force --sign - "$RESOURCES/dji-at-helper"
find "$RESOURCES/lpac/lib" "$RESOURCES/lpac/driver" -type f -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$RESOURCES/lpac/lpac"
codesign --force --deep --sign - "$APP_DIR"

mkdir -p "$DIST_DIR"
rm -rf "$FINAL_APP_DIR"
mv "$APP_DIR" "$FINAL_APP_DIR"
xattr -cr "$FINAL_APP_DIR"
codesign --force --deep --sign - "$FINAL_APP_DIR"

echo "$FINAL_APP_DIR"
