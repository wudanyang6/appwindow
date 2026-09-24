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

# 未公证应用从网络下载会被 Gatekeeper 拦（提示「无法验证…是否包含恶意软件」），
# DMG 内附放行说明，用户挂载后即可看到
cat > "$STAGING/⚠️ 首次打开必读.txt" <<'TXT'
AppWindow 首次打开说明
========================================

本应用未经 Apple 付费公证，从浏览器下载后 macOS 会提示
「无法验证"AppWindow.app"是否包含恶意软件」。
这是未公证应用的正常 Gatekeeper 提示，按任一方法放行一次即可，
之后正常双击使用。（注意：macOS 15 / 26 上「右键 → 打开」已失效）

方法一 · 图形界面（推荐）
  1. 先把 AppWindow 拖进左侧的「应用程序」文件夹
  2. 在「应用程序」里双击 AppWindow，弹出无法验证的提示，点「完成」
  3. 打开 系统设置 → 隐私与安全性
  4. 滑到底部「安全性」区，找到 "已阻止 AppWindow…"，点「仍要打开」
  5. 再次点「仍要打开」确认

方法二 · 终端一行命令
  把 AppWindow 拖进「应用程序」后，打开「终端」执行：

      xattr -dr com.apple.quarantine /Applications/AppWindow.app

  然后正常双击打开。

首次运行还需在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 AppWindow，
用于监听 Cmd+Tab / Cmd+` 快捷键并切换窗口（仅读窗口标题，无需屏幕录制）。
TXT

hdiutil create -volname "AppWindow" \
    -srcfolder "$STAGING" \
    -ov -format UDBZ \
    "$DMG" >/dev/null

echo
echo "✓ DMG 已生成: $DMG"
