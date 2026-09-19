# AppWindow

**[→ 在线介绍页](https://wudanyang6.github.io/appwindow/)**

一个只做一件事的 macOS 窗口切换器：用更顺手的方式在**应用**与**窗口**之间切换。灵感来自 [Contexts](https://contexts.co/)，只保留并增强了它最核心的两个快捷键——`Cmd+\`` 与 `Cmd+Tab`。

原生 `Cmd+Tab` 切换应用时看不到窗口、只能逐个循环；原生 Cmd+` 在应用内切窗口同样是一步步试。AppWindow 把这两件事变成**可见、可预览、可鼠标参与**的选择面板。

## 功能

### Cmd+Tab —— 应用切换器

按住 `Cmd` 再按 `Tab`，屏幕中央出现横向图标面板（尺寸贴近原生）：

- `Tab` / `→` 前进，`Shift+Tab` / `←` / `` ` `` 后退
- `↑` / `↓` 在当前高亮应用的窗口列表中选窗口，松开 `Cmd` 直达该窗口
- 鼠标：悬停图标或窗口行移动高亮、点击直接切换、滚轮切换应用、在窗口列表上滚动浏览
- 应用按最近使用排序，窗口超过可视行数时列表连续滚动（带上下箭头指示）
- **每个屏幕同时显示一份**，状态跨屏同步

### Cmd+` —— 当前应用窗口切换器

按住 `Cmd` 再按 `` ` ``，屏幕中央弹出当前应用的全部窗口列表（高度约为屏幕的 70%）：

- 继续按 `` ` `` 向下循环，`↑` / `↓` 移动，松开 `Cmd` 切换
- 鼠标：悬停移动高亮（松开即切换到悬停窗口）、点击直选、滚轮滚动列表
- 单窗口应用同样弹出（快速回到该窗口）

### 其他

- `Esc` 或点击面板外任意位置取消本次切换
- 面板为非激活窗口，不抢占键盘焦点，全程跟手
- 需要系统外观深浅模式，背景毛玻璃半透明
- 菜单栏常驻（无 Dock 图标），可主动触发系统授权弹窗

## 安装

### 下载安装

从 [Releases](../../releases) 下载最新的 DMG，打开后将 AppWindow 拖入 Applications。

> 首次运行需要在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 AppWindow（菜单栏图标可直达）。若打开时被 Gatekeeper 拦截，请右键 → 打开。

### 源码构建

要求：macOS 14+、Xcode Command Line Tools。

```bash
./scripts/build-app.sh      # 编译并组装 AppWindow.app
./scripts/package-dmg.sh    # （可选）打包 DMG
```

## 已知限制

- 跨 Space / 全屏应用内的切换依赖系统 activate 行为，个别场景可能不跳转到目标窗口所在 Space
- 使用私有 API `_AXUIElementGetWindow` 做 CGWindow 与 AXWindow 的匹配（dlsym 动态解析，缺失时自动退化为窗口 bounds 匹配）；因此**不可上架 App Store**
- 固定监听物理键 keycode 50（ANSI Grave），不跟随系统自定义快捷键
- 窗口标题取自 Accessibility API，无需屏幕录制权限

## 技术实现

Swift + AppKit（SPM 构建），核心组件：

```
Sources/Context/
├── main.swift              # 入口，accessory 应用（无 Dock 图标）
├── AppDelegate.swift       # 菜单栏、辅助功能权限引导与轮询
├── EventTapManager.swift   # CGEventTap + 键盘状态机（核心交互逻辑）
├── AppSwitcherPanel.swift  # Cmd+Tab 图标面板 + 窗口列表（多屏）
├── SwitchPanel.swift       # Cmd+` 窗口列表面板（多屏）
├── WindowListService.swift # 窗口枚举：CGWindowList z-order + AX 标题/引用
├── WindowActivator.swift   # 窗口激活：最小化恢复 → AXRaise → activate
├── ListScrolling.swift     # 列表连续滚动控制器 + 滚轮响应容器
├── AXHelpers.swift         # AX API Swift 封装 + 私有符号隔离
└── Theme.swift             # 全局面板外观设置
```

## License

[GPL-3.0](LICENSE)——使用或修改本软件的项目同样需要以 GPL-3.0 开源。
