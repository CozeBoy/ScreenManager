#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/屏幕管理.app"
ICONSET="$ROOT/.build/AppIcon.iconset"
ICON="$ROOT/Resources/AppIcon.icns"

cd "$ROOT"
swift build -c release
mkdir -p "$ROOT/Resources"
swift "$ROOT/Scripts/generate_app_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/ScreenOff" "$APP/Contents/MacOS/ScreenOff"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ScreenOff</string>
    <key>CFBundleIdentifier</key><string>local.screenoff.manager</string>
    <key>CFBundleName</key><string>屏幕管理</string>
    <key>CFBundleDisplayName</key><string>屏幕管理</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
echo "已生成：$APP"
