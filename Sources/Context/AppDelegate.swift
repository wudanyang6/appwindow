import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let panel = SwitchPanel()
    private lazy var eventTapManager = EventTapManager(panel: panel)
    private var permissionTimer: Timer?
    private var isTapRunning = false
    private var updateChecker: UpdateChecker?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        initializeAccess()
        setupUpdateChecker()
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

        // 更新检查：idle 显示检查入口，出结果后显示版本状态
        let updateItem: NSMenuItem
        switch updateChecker?.state {
        case .available(let latest):
            updateItem = NSMenuItem(
                title: "有新版本 \(latest) 可用",
                action: #selector(openReleasePage),
                keyEquivalent: ""
            )
            updateItem.target = self
        case .upToDate(let current):
            updateItem = NSMenuItem(
                title: "已是最新版本 (\(current))",
                action: nil,
                keyEquivalent: ""
            )
            updateItem.isEnabled = false
        default:
            updateItem = NSMenuItem(
                title: "检查更新…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            updateItem.target = self
        }
        menu.addItem(updateItem)
        menu.addItem(.separator())

        let status = NSMenuItem(
            title: isTapRunning ? "✓ 辅助功能权限已授权" : "✗ 缺少辅助功能权限",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)

        // 未授权时提供主动触发系统授权弹窗的入口（拒绝后系统弹窗不再自动出现）
        if !isTapRunning {
            let request = NSMenuItem(
                title: "请求辅助功能权限…",
                action: #selector(requestAccess),
                keyEquivalent: ""
            )
            request.target = self
            menu.addItem(request)
        }

        let settings = NSMenuItem(
            title: "打开系统设置…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        // 对齐系统 cmd+tab 的按住显示行为：快速点按直接切换，不闪面板
        let delayedPanel = NSMenuItem(
            title: "延迟显示面板（100ms）",
            action: #selector(toggleDelayedPanel(_:)),
            keyEquivalent: ""
        )
        delayedPanel.target = self
        delayedPanel.state = Settings.delayedPanel ? .on : .off
        menu.addItem(delayedPanel)

        // 排查工具：默认关闭，开启后写 ~/Library/Logs/AppWindow.log 供问题定位
        let diagLog = NSMenuItem(
            title: "诊断日志",
            action: #selector(toggleDiagLog(_:)),
            keyEquivalent: ""
        )
        diagLog.target = self
        diagLog.state = DiagLog.isEnabled ? .on : .off
        menu.addItem(diagLog)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 AppWindow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(quit)

        return menu
    }

    @objc private func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 菜单打开状态下切换 state 即实时生效；持久化由 Settings.delayedPanel 的 setter 完成
    @objc private func toggleDelayedPanel(_ item: NSMenuItem) {
        Settings.delayedPanel.toggle()
        item.state = Settings.delayedPanel ? .on : .off
    }

    /// 菜单打开状态下切换 state 即实时生效；持久化由 DiagLog.isEnabled 的 setter 完成
    @objc private func toggleDiagLog(_ item: NSMenuItem) {
        DiagLog.isEnabled.toggle()
        item.state = DiagLog.isEnabled ? .on : .off
    }

    /// 主动弹出系统授权请求对话框（用户此前拒绝后，系统不会再自动弹）
    @objc private func requestAccess() {
        promptForAccess()
    }

    // MARK: - 更新检测

    private func setupUpdateChecker() {
        let checker = UpdateChecker()
        checker.onStateChanged = { [weak self] in
            self?.statusItem?.menu = self?.buildMenu()
        }
        updateChecker = checker
        // 延迟数秒启动检测，避免挤占应用启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak checker] in
            checker?.start()
        }
    }

    @objc private func checkForUpdates() {
        updateChecker?.checkNow()
    }

    @objc private func openReleasePage() {
        updateChecker?.openReleasePage()
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
