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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$ROOT/.build/$CONFIG/AppWindow" "$APP/Contents/MacOS/AppWindow"
cp "$ROOT/assets/AppWindow.icns" "$APP/Contents/Resources/AppWindow.icns"
cp "$ROOT/ThirdPartyLicenses/Sparkle.txt" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

# 随包嵌入 Sparkle（SPM artifact 里的 xcframework 切片），并给主二进制补 bundle 内 rpath；
# install_name_tool 会破坏已有签名，必须在 codesign 之前执行
SPARKLE_FRAMEWORK_SOURCE="$(find "$ROOT/.build/artifacts" -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' -type d -print -quit)"
if [ -z "$SPARKLE_FRAMEWORK_SOURCE" ]; then
    echo "错误：.build/artifacts 下没有 Sparkle.framework（先 swift build）" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/AppWindow" | grep -Fq 'path @executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/AppWindow"
fi

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
    <string>0.9.0-beta.1</string>
    <key>CFBundleVersion</key>
    <string>13</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>AppWindow 需要辅助功能权限来监听 Cmd+` 快捷键并在窗口间切换。</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/wudanyang6/appwindow/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>5jdchZOVjxhYcZKhWbILDSRu6VW7YLesqurthc4W05g=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

# 本地端到端验证用：把测试构建指向测试 appcast，不影响默认 feed
if [ -n "${SU_FEED_URL:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SU_FEED_URL" "$APP/Contents/Info.plist"
fi

# CI 环境没有本地自签身份（AppWindowDev 只在本机钥匙串），沿用历史 CI 的 ad-hoc 签名；
# 本地保持 AppWindowDev 固定身份，TCC 授权跨构建稳定
if [ "${CI:-}" = "true" ]; then
    SIGN_IDENTITY="-"
    echo "==> codesign (ad-hoc, CI)"
else
    SIGN_IDENTITY="AppWindowDev"
    echo "==> codesign (AppWindowDev 固定身份, TCC 授权跨构建稳定)"
fi

# 先签 framework（--deep 覆盖内部 XPC/Autoupdate 嵌套组件）再签 app；
# 顺序反了会把未签名的嵌套组件固化进外层 seal，导致更新安装失败
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo

# 已有系统安装时替换为新构建并重启（保持日常使用入口不变）；
# SKIP_INSTALL=1 跳过替换，用于本地调试旧版本等不想被覆盖的场景
if [ "${SKIP_INSTALL:-}" != "1" ] && [ -d "/Applications/AppWindow.app" ]; then
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
