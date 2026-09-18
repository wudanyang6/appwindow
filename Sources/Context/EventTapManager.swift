import AppKit
import Carbon.HIToolbox

/// 全局键盘状态机，两种互斥的选择模式：
/// - cmd+`：当前应用的窗口列表（SwitchPanel）
/// - cmd+tab：应用切换器，高亮应用下方可选窗口（AppSwitcherPanel）
/// 松开 cmd 提交切换。事件 tap 挂在 main runloop 上，回调与状态全部在主线程，无需加锁。
final class EventTapManager {

    private enum Mode {
        case windows
        case apps
    }

    private let windowPanel: SwitchPanel
    private let appPanel = AppSwitcherPanel()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var mode: Mode?

    // windows 模式状态
    private var items: [WindowItem] = []
    private var selection = 0
    private var targetApp: NSRunningApplication?

    // apps 模式状态
    private var switcherApps: [SwitcherApp] = []
    private var appIndex = 0
    private var windowIndex = 0

    private var timeoutWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?

    private static let selectionTimeout: TimeInterval = 30

    init(panel: SwitchPanel) {
        self.windowPanel = panel

        // 选择过程中用户用鼠标切走了目标应用，面板失去意义，立即收起
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.mode != nil else { return }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // apps 模式没有固定的目标应用（targetApp 为 nil），用户主动切走即取消
            if frontPID != self.targetApp?.processIdentifier {
                self.cancelSelection()
            }
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    /// 创建全局事件监听；失败通常意味着辅助功能权限未授予。
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEvent(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }
}

// MARK: - 事件处理

private extension EventTapManager {

    private func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 回调处理过慢时系统会禁用 tap，立即恢复
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // flagsChanged 必须透传，否则系统修饰键状态会与物理按键错位
            if mode != nil && !event.flags.contains(.maskCommand) {
                commitSelection()
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return handleKeyDown(event)

        case .keyUp:
            return handleKeyUp(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasCmd = flags.contains(.maskCommand)

        if let mode {
            return handleKeyDownInMode(mode, keyCode: keyCode, flags: flags, event: event)
        }

        if keyCode == kVK_ANSI_Grave, hasCmd, !flags.contains(.maskShift) {
            return beginWindowSelection() ? nil : Unmanaged.passUnretained(event)
        }
        if keyCode == kVK_Tab, hasCmd {
            return beginAppSwitching(reverse: flags.contains(.maskShift))
                ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDownInMode(_ mode: Mode, keyCode: Int, flags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)

        switch mode {
        case .windows:
            switch keyCode {
            case kVK_ANSI_Grave where hasCmd:
                moveSelection(by: 1)
                return nil
            case kVK_UpArrow:
                moveSelection(by: -1)
                return nil
            case kVK_DownArrow:
                moveSelection(by: 1)
                return nil
            case kVK_Escape:
                cancelSelection()
                return nil
            case kVK_Tab:
                // 模式互斥：处于窗口模式时吞掉 tab，避免系统应用切换器叠加触发
                return nil
            default:
                // 其他按键意味着用户意图已变，收起面板但把事件还给系统
                cancelSelection()
                return Unmanaged.passUnretained(event)
            }

        case .apps:
            switch keyCode {
            case kVK_Tab where hasCmd && !hasShift:
                moveApp(by: 1)
                return nil
            case kVK_Tab where hasCmd:
                moveApp(by: -1)
                return nil
            case kVK_RightArrow:
                moveApp(by: 1)
                return nil
            case kVK_LeftArrow:
                moveApp(by: -1)
                return nil
            case kVK_UpArrow:
                moveWindow(by: -1)
                return nil
            case kVK_DownArrow:
                moveWindow(by: 1)
                return nil
            case kVK_Escape:
                cancelSelection()
                return nil
            case kVK_ANSI_Grave:
                // 等价向左：高亮往回移动一个应用
                moveApp(by: -1)
                return nil
            default:
                cancelSelection()
                return Unmanaged.passUnretained(event)
            }
        }
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let handledInMode = [kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow, kVK_Escape]

        if keyCode == kVK_ANSI_Grave && flags.contains(.maskCommand) {
            return nil
        }
        if keyCode == kVK_Tab && flags.contains(.maskCommand) {
            return nil
        }
        if mode != nil && handledInMode.contains(keyCode) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - 状态机

private extension EventTapManager {

    private func beginWindowSelection() -> Bool {
        guard mode == nil,
              let app = NSWorkspace.shared.frontmostApplication else { return false }

        let windows = WindowListService.windows(of: app)
        guard !windows.isEmpty else { return false }

        mode = .windows
        items = windows
        // 多窗口时默认高亮下一个窗口（与系统 cmd+` 预期一致），单窗口高亮唯一窗口
        selection = windows.count >= 2 ? 1 : 0
        targetApp = app
        startTimeout()

        windowPanel.show(
            items: windows,
            appIcon: app.icon,
            selected: selection,
            onPick: { [weak self] index in
                self?.pickWindowItem(at: index)
            },
            onHover: { [weak self] index in
                self?.hoverWindowItem(at: index)
            }
        )
        startOutsideClickMonitor()
        return true
    }

    private func beginAppSwitching(reverse: Bool) -> Bool {
        guard mode == nil else { return true }

        var apps = WindowListService.switcherApps()
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            ensureFrontmostFirst(&apps, frontmost: frontmost)
        }
        guard apps.count >= 2 else { return false }

        switcherApps = apps
        // 原生行为：cmd+tab 默认下一个应用，cmd+shift+tab 从最后一个（上一个使用的应用）开始
        appIndex = reverse ? apps.count - 1 : 1
        windowIndex = 0
        loadWindows(at: appIndex)
        mode = .apps
        startTimeout()

        appPanel.show(
            apps: switcherApps,
            appIndex: appIndex,
            windows: switcherApps[appIndex].windows,
            windowIndex: windowIndex,
            onPickApp: { [weak self] in self?.pickApp(at: $0) },
            onHoverApp: { [weak self] in self?.hoverApp(at: $0) },
            onPickWindow: { [weak self] in self?.pickWindow(at: $0) },
            onHoverWindow: { [weak self] in self?.hoverWindow(at: $0) },
            onScrollApp: { [weak self] in self?.moveApp(by: $0) }
        )
        startOutsideClickMonitor()
        return true
    }

    /// 确保当前前台应用排第一位（CGWindowList 的 z-order 通常已保证，此处兜底）
    private func ensureFrontmostFirst(_ apps: inout [SwitcherApp], frontmost: NSRunningApplication) {
        let frontPID = frontmost.processIdentifier
        if let index = apps.firstIndex(where: { $0.app.processIdentifier == frontPID }), index != 0 {
            // 不用 Array.move(fromOffsets:)：那是 SwiftUI 的扩展，会把 SwiftUICore 拉进链接
            let app = apps.remove(at: index)
            apps.insert(app, at: 0)
        } else if !apps.contains(where: { $0.app.processIdentifier == frontPID }) {
            apps.insert(SwitcherApp(app: frontmost), at: 0)
        }
    }

    // MARK: apps 模式操作

    private func moveApp(by delta: Int) {
        let count = switcherApps.count
        guard count > 0 else { return }

        appIndex = ((appIndex + delta) % count + count) % count
        windowIndex = 0
        loadWindows(at: appIndex)
        appPanel.selectApp(index: appIndex,
                           windows: switcherApps[appIndex].windows,
                           selectedWindow: windowIndex)
    }

    private func moveWindow(by delta: Int) {
        guard switcherApps.indices.contains(appIndex) else { return }
        let windows = switcherApps[appIndex].windows
        guard !windows.isEmpty else { return }

        let count = windows.count
        windowIndex = ((windowIndex + delta) % count + count) % count
        appPanel.selectWindow(index: windowIndex)
    }

    /// 窗口列表惰性加载：只在应用首次被高亮时做 AX 枚举，保证首按 cmd+tab 的响应速度
    private func loadWindows(at index: Int) {
        guard switcherApps.indices.contains(index), !switcherApps[index].windowsLoaded else { return }
        switcherApps[index].windows = WindowListService.windows(of: switcherApps[index].app)
        switcherApps[index].windowsLoaded = true
    }

    private func pickApp(at index: Int) {
        guard mode == .apps, switcherApps.indices.contains(index) else { return }
        appIndex = index
        windowIndex = 0
        loadWindows(at: index)
        commitSelection()
    }

    /// 鼠标悬停图标：只移动高亮，不提交
    private func hoverApp(at index: Int) {
        guard mode == .apps, switcherApps.indices.contains(index), index != appIndex else { return }
        appIndex = index
        windowIndex = 0
        loadWindows(at: index)
        appPanel.selectApp(index: appIndex,
                           windows: switcherApps[appIndex].windows,
                           selectedWindow: windowIndex)
    }

    private func pickWindow(at index: Int) {
        guard mode == .apps, switcherApps.indices.contains(appIndex),
              switcherApps[appIndex].windows.indices.contains(index) else { return }
        windowIndex = index
        commitSelection()
    }

    private func hoverWindow(at index: Int) {
        guard mode == .apps else { return }
        windowIndex = index
        // 同步面板高亮，否则悬停无视觉反馈
        appPanel.selectWindow(index: index)
    }

    // MARK: windows 模式操作

    private func pickWindowItem(at index: Int) {
        guard mode == .windows, items.indices.contains(index) else { return }
        selection = index
        commitSelection()
    }

    /// 鼠标悬停窗口行：同步提交状态，松开 cmd 时切换到悬停高亮的窗口
    private func hoverWindowItem(at index: Int) {
        guard mode == .windows, items.indices.contains(index) else { return }
        selection = index
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selection = ((selection + delta) % count + count) % count
        windowPanel.select(index: selection)
    }

    // MARK: 提交与收尾

    private func commitSelection() {
        switch mode {
        case .windows:
            guard items.indices.contains(selection), let app = targetApp else {
                endSelection()
                return
            }
            let item = items[selection]
            endSelection()
            WindowActivator.activate(item, app: app)

        case .apps:
            guard switcherApps.indices.contains(appIndex) else {
                endSelection()
                return
            }
            let target = switcherApps[appIndex]
            let window = target.windows.indices.contains(windowIndex)
                ? target.windows[windowIndex]
                : nil
            endSelection()
            if let window {
                WindowActivator.activate(window, app: target.app)
            } else {
                target.app.activate()
            }

        case nil:
            break
        }
    }

    private func cancelSelection() {
        guard mode != nil else { return }
        endSelection()
    }

    private func endSelection() {
        mode = nil
        items = []
        targetApp = nil
        switcherApps = []
        timeoutWork?.cancel()
        timeoutWork = nil
        stopOutsideClickMonitor()
        windowPanel.dismiss()
        appPanel.dismiss()
    }

    /// 状态机异常兜底：面板滞留过久（如 modifier 状态丢失）自动收起
    private func startTimeout() {
        let work = DispatchWorkItem { [weak self] in self?.cancelSelection() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionTimeout, execute: work)
    }

    // MARK: 面板外点击取消

    /// 全局监听面板外的鼠标点击（global monitor 只收本应用之外的事件，
    /// 点击面板自身不会触发），点击即取消切换
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.cancelSelection()
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
