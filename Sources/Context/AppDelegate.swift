import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let panel = SwitchPanel()
    private lazy var eventTapManager = EventTapManager(panel: panel)
    private var permissionTimer: Timer?
    private var isTapRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        initializeAccess()
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

    /// 主动弹出系统授权请求对话框（用户此前拒绝后，系统不会再自动弹）
    @objc private func requestAccess() {
        promptForAccess()
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
