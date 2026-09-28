#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/屏幕管理.app"
DMG="$ROOT/build/屏幕管理.dmg"
STAGING="$(mktemp -d /private/tmp/screenoff-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

if [[ ! -d "$APP" ]]; then
    echo "应用不存在，请先运行 ./build_app.sh" >&2
    exit 1
fi

ditto "$APP" "$STAGING/屏幕管理.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
    -volname "屏幕管理" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    "$DMG"
hdiutil verify "$DMG"
echo "已生成：$DMG"
