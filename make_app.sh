#!/bin/zsh
# Packages the GUI as a menu-bar .app. A bare SwiftPM executable cannot be a
# menu-bar app: it needs a bundle with LSUIElement so it runs without a Dock
# icon or main window.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="RE2Trainer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RE2TrainerGUI "$APP/Contents/MacOS/RE2Trainer"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>RE2Trainer</string>
  <key>CFBundleIdentifier</key>      <string>local.re2trainer</string>
  <key>CFBundleExecutable</key>      <string>RE2Trainer</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>
  <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
echo "run with:  sudo $PWD/$APP/Contents/MacOS/RE2Trainer"
