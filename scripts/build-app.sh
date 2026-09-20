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
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>5</string>
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

# CI 环境没有本地自签身份（AppWindowDev 只在本机钥匙串），沿用历史 CI 的 ad-hoc 签名；
# 本地保持 AppWindowDev 固定身份，TCC 授权跨构建稳定
if [ "${CI:-}" = "true" ]; then
    echo "==> codesign (ad-hoc, CI)"
    codesign --force --sign - "$APP"
else
    echo "==> codesign (AppWindowDev 固定身份, TCC 授权跨构建稳定)"
    codesign --force --sign "AppWindowDev" "$APP"
fi

echo

# 已有系统安装时替换为新构建并重启（保持日常使用入口不变）
if [ -d "/Applications/AppWindow.app" ]; then
    # 按可执行文件名匹配杀掉所有实例（含 build 目录手动 open 的旧实例），
    # 只按 /Applications 路径匹配会漏杀后者，造成双实例同时挂 EventTap
    pkill -f "AppWindow.app/Contents/MacOS/AppWindow" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/AppWindow.app
    cp -R "$APP" /Applications/AppWindow.app
    open /Applications/AppWindow.app
    echo "✓ 已安装到 /Applications 并重启"
fi

echo "✓ 构建完成: $APP"
echo "  运行: open \"$APP\""
echo "  首次运行需在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 AppWindow"
