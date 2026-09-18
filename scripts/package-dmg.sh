#!/bin/bash
# 将 build/AppWindow.app 打包为 DMG 安装包（App + Applications 拖拽安装布局）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="$(defaults read "$ROOT/build/AppWindow.app/Contents/Info.plist" CFBundleShortVersionString)"
STAGING="$ROOT/build/dmg-staging"
DMG="$ROOT/dist/AppWindow-$VERSION.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" "$ROOT/dist"

ditto "$ROOT/build/AppWindow.app" "$STAGING/AppWindow.app"
ln -sfn /Applications "$STAGING/Applications"

hdiutil create -volname "AppWindow" \
    -srcfolder "$STAGING" \
    -ov -format UDBZ \
    "$DMG" >/dev/null

echo
echo "✓ DMG 已生成: $DMG"
