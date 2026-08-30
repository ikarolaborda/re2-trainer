#!/bin/zsh
# Packages the GUI as a double-clickable .app.
#
# The trainer needs root for task_for_pid, so it used to be started with sudo
# from a terminal. The bundle now re-launches itself through the standard macOS
# administrator prompt (see Privilege.swift), which means it can be opened from
# the Dock, Finder or Launchpad like any other app.
set -e
cd "$(dirname "$0")"
swift build -c release

APP="RE2Trainer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RE2TrainerGUI "$APP/Contents/MacOS/RE2Trainer"

# Icon is drawn in code, so there is no binary asset in the repo.
ICONSET="$(mktemp -d)/icon.iconset"
swift tools/make_icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/RE2Trainer.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>RE2 Trainer</string>
  <key>CFBundleDisplayName</key>     <string>RE2 Trainer</string>
  <key>CFBundleIdentifier</key>      <string>local.re2trainer</string>
  <key>CFBundleExecutable</key>      <string>RE2Trainer</string>
  <key>CFBundleIconFile</key>        <string>RE2Trainer</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.1</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built $APP"

if [[ "$1" == "install" ]]; then
  sudo rm -rf "/Applications/RE2 Trainer.app"
  sudo cp -R "$APP" "/Applications/RE2 Trainer.app"
  echo "installed to /Applications/RE2 Trainer.app"
fi
