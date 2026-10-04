import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let panel = SwitchPanel()
    private lazy var eventTapManager = EventTapManager(panel: panel)
    private var permissionTimer: Timer?
    private var isTapRunning = false
    private let updaterManager = UpdaterManager()
    // 弱引用菜单项：菜单重建时重新绑定（菜单持有 item 的生命周期）
    private weak var updateMenuItem: NSMenuItem?
    private lazy var settingsWindowController = SettingsWindowController(
        updaterManager: updaterManager,
        eventTapManager: eventTapManager,
        isAccessibilityGranted: { [weak self] in self?.isTapRunning == true }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        initializeAccess()
        // 先接线再启动：启动触发的首轮检查也要能刷新菜单标题
        updaterManager.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.updateMenuItem?.title = self.updateMenuTitle(for: state)
        }
        updaterManager.start()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "AppWindow")
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 关于：系统标准关于面板（名称/版本/图标读自 Info.plist），置顶入口
        let about = NSMenuItem(title: "关于 AppWindow", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        // 更新：检查入口，标题由 UpdaterManager 状态机驱动（检查更新… / 正在检查… / 已是最新 / 有新版本）
        let checkUpdate = NSMenuItem(
            title: updateMenuTitle(for: updaterManager.updateMenuState),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdate.target = self
        updateMenuItem = checkUpdate
        menu.addItem(checkUpdate)

        // 设置：普通窗口承载全部偏好开关
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        // 辅助功能权限：状态与引导收进子菜单，主菜单保持精简
        let accessMenu = NSMenu()
        let status = NSMenuItem(
            title: isTapRunning ? "✓ 辅助功能权限已授权" : "✗ 缺少辅助功能权限",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        accessMenu.addItem(status)

        // 未授权时提供主动触发系统授权弹窗的入口（拒绝后系统弹窗不再自动出现）
        if !isTapRunning {
            let request = NSMenuItem(
                title: "请求辅助功能权限…",
                action: #selector(requestAccess),
                keyEquivalent: ""
            )
            request.target = self
            accessMenu.addItem(request)
        }

        let openSystemSettings = NSMenuItem(
            title: "打开系统设置…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        openSystemSettings.target = self
        accessMenu.addItem(openSystemSettings)

        let access = NSMenuItem(title: "辅助功能权限", action: nil, keyEquivalent: "")
        access.submenu = accessMenu
        menu.addItem(access)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 AppWindow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(quit)

        return menu
    }

    /// 系统标准关于面板：名称/版本/图标自动读自 Info.plist，credits 补描述、项目链接与协议。
    /// accessory 应用无 Dock 图标，先激活自身面板才会前置可见
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: aboutCredits()])
    }

    /// 关于面板正文：一句话描述 + 可点击的项目主页链接 + 开源协议，居中排版贴近原生
    private func aboutCredits() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let credits = NSMutableAttributedString(
            string: "液态玻璃风格的 Cmd+Tab / Cmd+` 窗口切换器\n",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "项目主页与源码",
            attributes: [.font: font,
                         .link: URL(string: "https://github.com/wudanyang6/appwindow")!]))
        credits.append(NSAttributedString(
            string: "\n以 GPL-3.0 协议开源",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        credits.append(NSAttributedString(
            string: "\n自动更新由 ",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        credits.append(NSAttributedString(
            string: "Sparkle",
            attributes: [.font: font, .link: URL(string: "https://sparkle-project.org")!]))
        credits.append(NSAttributedString(
            string: " 提供",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        credits.addAttribute(.paragraphStyle, value: paragraph,
                             range: NSRange(location: 0, length: credits.length))
        return credits
    }

    @objc private func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 设置窗口承载全部偏好开关；打开前会同步各控件当前值
    @objc private func openSettings() {
        settingsWindowController.show()
    }

    /// 主动弹出系统授权请求对话框（用户此前拒绝后，系统不会再自动弹）
    @objc private func requestAccess() {
        promptForAccess()
    }

    // MARK: - 更新

    /// 菜单标题映射：状态机 → 「检查更新…」动态标题
    private func updateMenuTitle(for state: UpdateMenuState) -> String {
        switch state {
        case .idle:
            return "检查更新…"
        case .checking:
            return "正在检查…"
        case .upToDate(let version):
            return "已是最新（\(version)）"
        case .available(let version):
            return "有新版本 v\(version) 可用"
        }
    }

    @objc private func checkForUpdates() {
        updaterManager.checkForUpdates()
    }

    // MARK: - 权限

    private func initializeAccess() {
        if AXIsProcessTrusted() {
            startEventTap()
        } else {
            // 系统引导弹窗只在启动时弹一次；拒绝后靠菜单栏入口主动引导，不再骚扰
            promptForAccess()
            startPermissionPolling()
        }
    }

    private func startEventTap() {
        guard !isTapRunning else { return }
        isTapRunning = eventTapManager.start()
        statusItem?.menu = buildMenu()
    }

    private func promptForAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 用户在系统设置里手动勾选后没有系统通知可监听，只能静默轮询感知；
    /// 轮询内绝不能再调带 prompt 的 API，否则拒绝后会反复弹窗
    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.stopPermissionPolling()
            self.startEventTap()
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// 检查进行中时置灰「检查更新…」（Sparkle 要求 canCheckForUpdates 为 true 才能调用）
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return updaterManager.canCheckForUpdates
        }
        return true
    }
}
