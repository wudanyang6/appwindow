#!/bin/bash
# 编译并组装 AppWindow.app（ad-hoc 签名，可直接 open 运行）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

APP="$ROOT/build/AppWindow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/AppWindow" "$APP/Contents/MacOS/AppWindow"
cp "$ROOT/assets/AppWindow.icns" "$APP/Contents/Resources/AppWindow.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AppWindow</string>
    <key>CFBundleIdentifier</key>
    <string>com.wudanyang.appwindow</string>
    <key>CFBundleName</key>
    <string>AppWindow</string>
    <key>CFBundleDisplayName</key>
    <string>AppWindow</string>
    <key>CFBundleIconFile</key>
    <string>AppWindow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.2</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>AppWindow 需要辅助功能权限来监听 Cmd+` 快捷键并在窗口间切换。</string>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo
echo "✓ 构建完成: $APP"
echo "  运行: open \"$APP\""
echo "  首次运行需在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 AppWindow"
