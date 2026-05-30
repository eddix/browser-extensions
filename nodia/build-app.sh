#!/usr/bin/env bash
# Builds nodia.app (release, ad-hoc signed) into dist/.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="nodia"
BUNDLE_ID="com.eddix.nodia"
VERSION="1.0.0"
APP="dist/$APP_NAME.app"

echo "▶ building release…"
swift build -c release

echo "▶ assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>nodia 通过 Arc 的脚本接口切换到你选中的标签页。</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▶ ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "✅ built $APP"
