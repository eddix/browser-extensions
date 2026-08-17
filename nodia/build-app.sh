#!/usr/bin/env bash
# Builds nodia.app (release, ad-hoc signed) into dist/.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="nodia"
BUNDLE_ID="com.eddix.nodia"
VERSION="1.0.0"
# Output into a hidden dir so Spotlight/Launchpad don't index this build copy
# as a second app (the real install lives in /Applications).
APP=".dist/$APP_NAME.app"

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
    <!-- 收藏库默认在 ~/Documents 下。没有这条声明，系统不会弹授权框，而是
         直接拒绝访问——表现为服务起不来、界面一直卡在「正在打开收藏库」。 -->
    <key>NSDocumentsFolderUsageDescription</key><string>nodia 把你保存的链接写进这里的 Obsidian 收藏库。</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 签名身份决定了系统隐私授权跟着谁走。ad-hoc 签名每次构建的哈希都不一样，
# 系统会当成一个全新的 app，上次授予的「文稿」权限随之作废——每装一次就得
# 重新授权一次。设了 NODIA_SIGN_IDENTITY（自签证书即可）身份才稳定。
SIGN_IDENTITY="${NODIA_SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "▶ ad-hoc signing…（每次重装都需重新授权文稿访问）"
else
    echo "▶ signing as $SIGN_IDENTITY …"
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "✅ built $APP"
