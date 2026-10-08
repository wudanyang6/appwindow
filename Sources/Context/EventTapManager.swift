import AppKit
import Carbon.HIToolbox

/// 全局键盘状态机，两种互斥的选择模式：
/// - 窗口切换键（默认 cmd+`）：当前应用的窗口列表（SwitchPanel）。**每按一次立即切换**到下一个窗口，
///   刚离开的窗口沉到循环队尾（原生 cmd+` 的循环栈），松开修饰键只收面板
/// - 应用切换键（默认 cmd+tab）：应用切换器，高亮应用下方可选窗口（AppSwitcherPanel），松开修饰键提交
/// 两个触发键都可在设置里录制更换（ShortcutStore，每事件实时读取，改键即生效）。
/// 事件 tap 挂在 main runloop 上，回调与状态全部在主线程，无需加锁。
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
    // 本次模式由哪个触发键（基础键，不含反向 Shift）启动：决定「松开修饰键提交」判据、
    // 模式内重复按键匹配与兜底轮询；每次 begin 时从当前配置快照，会话内不变
    private var modeTrigger: Shortcut?
    // 被本应用吞掉 keyDown 的键位：对应 keyUp 到达时精确回收，
    // 避免放行孤儿 keyUp（旧实现是「Cmd 仍按住就吞」，keyDown 放行时会把无关 keyUp 也吞掉）
    private var swallowedKeyUps: Set<UInt16> = []
    // 触发键配置：UserDefaults 有内存缓存，每事件读取的开销可忽略；热生效，无需重建 tap
    private var shortcuts: ShortcutConfiguration { ShortcutStore.configuration() }
    // 录制会话（weak：设置窗口销毁即失效）；非 nil 时键盘由会话处理
    private weak var recordingSession: ShortcutRecorderSession?

    // 预览重渲染节流间隔：拖杆时的高频回调合并到约 8Hz

    /// 应用切换会话或预览进行中：窗口加载/悬停/预取共用同一套 UI 路径
    private var isAppSwitcherUIActive: Bool { mode == .apps }

    // windows 模式状态
    private var items: [WindowItem] = []
    /// 本次切换会话的起点（按键进入时记）：打点「按键 → 面板上屏」的真实延迟。
    /// 排查「面板出现慢」以它为准——外部轮询窗口列表会被窗口服务器的快照延迟放大
    private var sessionStartedAt: TimeInterval = 0
    private var stallWatchTimer: Timer?
    // 光标 = 当前所在窗口在列表中的下标；hover 只移动它不切换，按键 / 点击同时切换
    private var selection = 0
    /// 最近一次真正激活过的窗口下标：键盘路径每次都已立即切换，只有鼠标悬停只移光标；
    /// 松开时据此判断要不要补一次激活
    private var activatedWindowIndex: Int?
    private var targetApp: NSRunningApplication?

    // apps 模式状态
    private var switcherApps: [SwitcherApp] = []
    private var appIndex = 0
    // 当前高亮应用中选中的窗口；默认 0 = 高亮列表第一行（提交走窗口级激活），
    // nil = 未选（仅点击图标提交时，走应用级激活）
    private var windowIndex: Int?

    // app 激活顺序（MRU，最近在前）；已退出 app 的残留 pid 在排序时匹配不到，自然跳过
    private var appMRU: [pid_t] = []

    // 窗口使用顺序（MRU）：app 失活快照维护，弥补 z-order 看不到跨 Space / 最小化窗口的顺序
    private let windowMRU = WindowMRUTracker()

    // dock 角标缓存（app 名 → 角标文字）：面板打开时先用缓存渲染，后台读 Dock 后更新
    private var dockBadges: [String: String] = [:]

    private var modifierWatchTimer: Timer?
    private var panelShowWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    // 方向键切换时的窗口枚举防抖：停在某应用 ~90ms 后才后台加载它的窗口，
    // 避免每按一次方向键都同步做一次 AX 枚举（实测单次可达 250ms）卡住主线程
    private var windowLoadWork: DispatchWorkItem?
    // 面板外滚轮切应用的增量累加器：累到阈值走一步（与面板内图标行同一手感）
    private var scrollAccumulator: CGFloat = 0

    // modifier 状态兜底轮询间隔：松开 cmd 的 flagsChanged 正常都会触发，
    // 轮询只在事件丢失（tap 异常）时才生效，无需高频
    private static let modifierWatchInterval: TimeInterval = 1
    private static let panelShowDelay: TimeInterval = 0.1
    // 滚轮切应用的步进阈值，与 ScrollContainerView 一致
    private static let scrollAppStepThreshold: CGFloat = 12
    // keyUp 里判断是否本模式消费的方向 / Esc 键：tap 收全系统按键，用 static 避免每次释放都新建数组
    private static let modeConsumedKeyUps: Set<UInt16> = [
        UInt16(kVK_UpArrow), UInt16(kVK_DownArrow), UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_Escape)
    ]

    init(panel: SwitchPanel) {
        self.windowPanel = panel

        // z-order 只是使用顺序的近似（app 激活对它的更新带“交换”语义），
        // MRU 以 z-order 播种，此后每次激活冒泡修正
        appMRU = WindowListService.switcherApps().map(\.app.processIdentifier)

        // 选择过程中用户用鼠标切走了目标应用，面板失去意义，立即收起；
        // 同时维护 app 激活顺序（MRU）。workspace 通知发布在 NSWorkspace 自己的
        // notificationCenter，注册到 NotificationCenter.default 会永远收不到
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                DiagLog.log("app-activate", "\(app.localizedName ?? "?")(\(app.processIdentifier))")
                self.noteAppActivation(app.processIdentifier)
            }
            guard self.mode != nil else { return }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // apps 模式没有固定的目标应用（targetApp 为 nil），用户主动切走即取消
            if frontPID != self.targetApp?.processIdentifier {
                self.cancelSelection()
            }
        }

        // 图标缓存跨会话保留，退出应用时清掉对应条目：pid 会被复用，
        // 留着会取到上一个应用的图标（见 AppIconCache）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            AppIconCache.remove(pid: app.processIdentifier)
        }

        // app 失活时刻的 focused + z 序正是「本次使用的最终状态」，快照进窗口 MRU；
        // 前台期间用户内部切窗（cmd+`、鼠标点击）不触发任何 app 级通知，靠此处与取用时刷新兜住
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.windowMRU.snapshot(app)
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    /// 创建全局事件监听；失败通常意味着辅助功能权限未授予。
    /// 开始录制触发键：先收掉进行中的切换会话，避免面板与录制抢键盘
    func beginRecording(_ session: ShortcutRecorderSession) {
        cancelSelection()
        recordingSession = session
    }

    /// 结束录制（幂等）：恢复键盘透传
    func endRecording() {
        recordingSession = nil
    }

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)

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
        // 录制会话优先：由 tap 吞键并直接回调录制器（录制 Cmd+Tab 时系统切换器不会叠加）；
        // 会话结束（捕获完成 / Esc / 取消）即恢复透传
        if let recordingSession {
            let consumed = recordingSession.handle(type, event)
            if recordingSession.isFinished {
                endRecording()
            }
            if consumed {
                return nil
            }
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 回调处理过慢时系统会禁用 tap，立即恢复
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // flagsChanged 必须透传，否则系统修饰键状态会与物理按键错位
            if mode != nil, let trigger = modeTrigger, !trigger.modifiers.isEmpty,
               !event.flags.intersection(Shortcut.modifierMask).isSuperset(of: trigger.modifiers) {
                // 两种模式都走 commitSelection：apps 是「松开修饰键提交」；
                // windows 虽是立即切换，但鼠标悬停只移光标，需要在松开时补一次激活
                commitSelection()
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return handleKeyDown(event)

        case .keyUp:
            return handleKeyUp(event)

        case .scrollWheel:
            return handleScroll(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 面板显示期间全局接管滚轮（不管指针在不在面板上、也不依赖面板视图自己收到事件，
    /// 因此兼容 Mouse Fix 等把滚轮改写/直投目标进程的工具）：
    /// - 指针在窗口列表上：滚列表
    /// - 其它（图标行 / 间隙 / 面板外）：切换应用
    /// 事件一律消费，避免下方应用同时被滚动
    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let mode, let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }

        // pixelScrollDelta 已归一化：普通鼠标（行增量）与触摸板/精确设备（像素）统一为像素
        let delta = ns.pixelScrollDelta
        let point = NSEvent.mouseLocation

        switch mode {
        case .windows:
            // 窗口模式只有列表，滚轮始终滚列表
            windowPanel.scrollList(by: delta)
        case .apps:
            if appPanel.listContains(point) {
                appPanel.scrollList(by: delta)
            } else {
                // 惯性阶段不参与切换，避免一次滑动甩过多应用；主动滑动与鼠标滚轮照常
                guard ns.momentumPhase.isEmpty else { return nil }
                scrollAccumulator += delta
                if abs(scrollAccumulator) >= Self.scrollAppStepThreshold {
                    let step = scrollAccumulator > 0 ? 1 : -1
                    scrollAccumulator = 0
                    moveApp(by: step)
                }
            }
        }
        return nil
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if let mode {
            return handleKeyDownInMode(mode, keyCode: keyCode, flags: flags, event: event)
        }

        // 入口精确匹配：命中基础键进正向、命中「基础键 + Shift」进反向；
        // 进入成功才吞掉 keyDown 并登记 keyUp（进入失败放行，keyUp 也不吞）
        let shortcuts = self.shortcuts
        if shortcuts.windowSwitcher.matchesEntry(keyCode: keyCode, flags: flags) {
            markSessionStart(event)
            if beginWindowSelection(reverse: false) {
                swallowedKeyUps.insert(keyCode)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if shortcuts.windowSwitcher.reversed.matchesEntry(keyCode: keyCode, flags: flags) {
            markSessionStart(event)
            if beginWindowSelection(reverse: true) {
                swallowedKeyUps.insert(keyCode)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if shortcuts.appSwitcher.matchesEntry(keyCode: keyCode, flags: flags) {
            markSessionStart(event)
            if beginAppSwitching(reverse: false) {
                swallowedKeyUps.insert(keyCode)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        if shortcuts.appSwitcher.reversed.matchesEntry(keyCode: keyCode, flags: flags) {
            markSessionStart(event)
            if beginAppSwitching(reverse: true) {
                swallowedKeyUps.insert(keyCode)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDownInMode(_ mode: Mode, keyCode: UInt16, flags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
        let hasShift = flags.contains(.maskShift)

        switch mode {
        case .windows:
            // 按住触发键连按：前进 / 后退一个窗口（Shift 反向）
            if let trigger = modeTrigger, trigger.matchesInMode(keyCode: keyCode, flags: flags) {
                stepWindow(by: hasShift ? -1 : 1)
                return nil
            }
            switch keyCode {
            case UInt16(kVK_DownArrow):
                stepWindow(by: 1)
                return nil
            case UInt16(kVK_UpArrow):
                stepWindow(by: -1)
                return nil
            case UInt16(kVK_Escape):
                // 立即切换模型下 Esc 只能停止轮换（已发生的切换不回退，与原生 cmd+` 一致）
                cancelSelection()
                return nil
            case shortcuts.appSwitcher.keyCode:
                // 模式互斥：处于窗口模式时吞掉应用切换键，避免系统应用切换器叠加触发；
                // 登记回收，其 keyUp 同样吞掉（旧实现按「Cmd 按住」无条件吞，这里是精确版）
                swallowedKeyUps.insert(keyCode)
                return nil
            default:
                // 其他按键意味着用户意图已变，收起面板但把事件还给系统
                cancelSelection()
                return Unmanaged.passUnretained(event)
            }

        case .apps:
            // 按住触发键连按：前进 / 后退一个应用（Shift 反向）
            if let trigger = modeTrigger, trigger.matchesInMode(keyCode: keyCode, flags: flags) {
                moveApp(by: hasShift ? -1 : 1)
                return nil
            }
            switch keyCode {
            case UInt16(kVK_RightArrow):
                moveApp(by: 1)
                return nil
            case UInt16(kVK_LeftArrow):
                moveApp(by: -1)
                return nil
            case UInt16(kVK_UpArrow):
                moveWindow(by: -1)
                return nil
            case UInt16(kVK_DownArrow):
                moveWindow(by: 1)
                return nil
            case UInt16(kVK_Escape):
                cancelSelection()
                return nil
            case shortcuts.windowSwitcher.keyCode:
                // 等价向左：高亮往回移动一个应用；登记回收其 keyUp
                swallowedKeyUps.insert(keyCode)
                moveApp(by: -1)
                return nil
            default:
                cancelSelection()
                return Unmanaged.passUnretained(event)
            }
        }
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))

        // 无修饰的功能键触发没有「松开修饰键」可等：keyUp 到达即提交 / 收面板
        if let trigger = modeTrigger, trigger.modifiers.isEmpty, trigger.keyCode == keyCode {
            commitSelection()
        }

        // 只吞本应用吞过 keyDown 的键：放行的 keyDown 不再被误吞 keyUp
        if swallowedKeyUps.remove(keyCode) != nil {
            return nil
        }
        if mode != nil && Self.modeConsumedKeyUps.contains(keyCode) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - 状态机

private extension EventTapManager {

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    /// 会话起点取事件时间戳（物理按下那一刻），而不是回调执行时刻：主线程被占住时回调会晚到，
    /// 用回调时刻会把「投递慢」错算进「上屏慢」。CGEvent 时间戳是自启动以来的纳秒，
    /// 与 systemUptime 同一时基（实测投递延迟 0.1–5ms）；合成事件时间戳为 0，回退到当前时刻
    private func markSessionStart(_ event: CGEvent) {
        startStallWatch()
        let eventTime = Double(event.timestamp) / 1_000_000_000
        sessionStartedAt = eventTime > 0 ? eventTime : ProcessInfo.processInfo.systemUptime
        if eventTime > 0 {
            DiagLog.log("panel", "按键→tap 投递 \(Self.elapsedMs(since: eventTime))ms")
        }
    }

    /// 诊断（定位「日志 164ms 但眼睛看 1-2 秒」）：上屏后每 20ms 探一次，
    /// 记录面板窗口何时进入窗口服务器的 on-screen 列表、何时被标为可见。
    /// 两者都早 = 窗口服务器已就位，慢在我们自己画；两者都晚 = 窗口服务器在上屏这一环
    private func tracePanelVisibility() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = sessionStartedAt
        var ticks = 0
        var reportedOnScreen = false
        var reportedVisible = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            ticks += 1
            var inList = false
            if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] {
                inList = list.contains { info in
                    (info[kCGWindowOwnerPID as String] as? pid_t) == pid
                        && ((info[kCGWindowLayer as String] as? Int) ?? 0) >= 1000
                }
            }
            let visible = self?.appPanel.isAnyPanelOcclusionVisible ?? false
            if inList, !reportedOnScreen {
                reportedOnScreen = true
                DiagLog.log("panel", "进 on-screen 列表：按键后 \(Self.elapsedMs(since: start))ms")
            }
            // occlusion 是窗口服务器认为「窗口真在屏上」的标志，它变真才算画出来了
            if visible, !reportedVisible {
                reportedVisible = true
                DiagLog.log("panel", "窗口服务器标为可见：按键后 \(Self.elapsedMs(since: start))ms")
            }
            if (reportedOnScreen && reportedVisible) || ticks >= 200 {
                if !reportedVisible {
                    DiagLog.log("panel", "窗口服务器始终未标可见（探测 \(ticks * 20)ms 结束）")
                }
                timer.invalidate()
            }
        }
    }

    /// 诊断：会话期间每 10ms 打点，主线程出现 >100ms 空档说明被同步调用（多为 AX）卡住——
    /// 卡顿期间面板画不出来，用户看到的就是「什么都没有，然后整块出现」
    private func startStallWatch() {
        stallWatchTimer?.invalidate()
        var last = ProcessInfo.processInfo.systemUptime
        stallWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
            let now = ProcessInfo.processInfo.systemUptime
            let gapMs = Int((now - last) * 1000)
            if gapMs > 100 {
                let since = self.map { Self.elapsedMs(since: $0.sessionStartedAt) } ?? -1
                DiagLog.log("stall", "主线程空档 \(gapMs)ms（按键后 \(since)ms）")
            }
            last = now
            if self?.mode == nil { timer.invalidate() }
        }
    }

    private func beginWindowSelection(reverse: Bool) -> Bool {
        guard mode == nil,
              let app = NSWorkspace.shared.frontmostApplication else { return false }

        let windows = currentWindows(for: app)
        guard !windows.isEmpty else { return false }

        mode = .windows
        items = windows
        // 正向：多窗口时默认高亮下一个窗口（与系统 cmd+` 预期一致），单窗口高亮唯一窗口；
        // 反向（触发键 + Shift）：从最后一个窗口开始
        selection = reverse ? windows.count - 1 : (windows.count >= 2 ? 1 : 0)
        targetApp = app
        // 会话内统一持基础触发键（不含反向 Shift）：Shift 只决定方向，中途松开 Shift 不结束会话
        modeTrigger = shortcuts.windowSwitcher
        startTimeout()

        // 先构建（与「延迟显示面板」的等待并行），到点只做上屏。
        // 延迟期间 selection 变化（cmd+` 已真切换过）由 windowPanel.select 直接更新已建好的内容
        windowPanel.prepare(
            items: items,
            appIcon: app.icon,
            selected: selection,
            onPick: { [weak self] in self?.pickWindowItem(at: $0) },
            onHover: { [weak self] in self?.hoverWindowItem(at: $0) }
        )
        showPanel { [weak self] in
            guard let self, self.mode == .windows else { return }
            self.windowPanel.present()
            DiagLog.log("panel", "窗口面板上屏：按键后 \(Self.elapsedMs(since: self.sessionStartedAt))ms")
        }
        startOutsideClickMonitor()
        // 立即切换：首次按下就前进到下一个窗口，与后续每次按键走同一条路径
        activateWindowItem(at: selection)
        return true
    }

    private func beginAppSwitching(reverse: Bool) -> Bool {
        guard mode == nil else { return true }

        var apps = mruOrdered(WindowListService.switcherApps())
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            ensureFrontmostFirst(&apps, frontmost: frontmost)
        }
        guard apps.count >= 2 else { return false }

        switcherApps = apps
        // 原生行为：正向默认下一个应用，反向从最后一个（上一个使用的应用）开始
        appIndex = reverse ? apps.count - 1 : 1
        // 默认高亮窗口列表第一行，松开即窗口级激活该窗口
        windowIndex = 0
        mode = .apps
        modeTrigger = shortcuts.appSwitcher
        startTimeout()

        // 首个应用的窗口也走后台枚举：不在事件 tap 回调里同步做 AX（慢应用可达数百 ms，
        // 会卡首按、还可能触发 tapDisabledByTimeout 丢事件）。列表首帧可能短暂为空再填充，
        // 与方向键 / 预取一致；快速点按的提交路径 commitSelection 另有同步兜底
        loadWindowsInBackground(at: appIndex)

        showAppPanel()
        refreshDockBadges()
        startOutsideClickMonitor()
        return true
    }

    /// 面板显示统一收口：开启「延迟显示面板」时按住 100ms 才出现，
    /// 快速点按（期间松开 cmd）不闪面板直接切换。display 到点执行；
    /// 到点前选择已结束（松开/Esc/点击）则 work 已被 endSelection 取消
    private func showPanel(_ display: @escaping () -> Void) {
        guard Settings.delayedPanel else {
            display()
            return
        }
        let work = DispatchWorkItem(block: display)
        panelShowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelShowDelay, execute: work)
    }

    /// app 面板显示：先构建（与「延迟显示面板」的等待并行），到点只做上屏。
    /// 延迟期间 tab 移动 / Esc 取消照常生效：面板未上屏时 selectApp 等调用直接更新
    /// 已建好的内容，到点呈现的就是最新状态
    private func showAppPanel() {
        guard switcherApps.indices.contains(appIndex) else { return }
        appPanel.prepare(
            apps: switcherApps,
            appIndex: appIndex,
            windows: switcherApps[appIndex].windows,
            windowIndex: windowIndex,
            badges: switcherApps.map { dockBadges[$0.name] },
            onPickApp: { [weak self] in self?.pickApp(at: $0) },
            onHoverApp: { [weak self] in self?.hoverApp(at: $0) },
            onPickWindow: { [weak self] in self?.pickWindow(at: $0) },
            onHoverWindow: { [weak self] in self?.hoverWindow(at: $0) },
            onScrollApp: { [weak self] in self?.moveApp(by: $0) },
            onCancel: { [weak self] in self?.cancelSelection() }
        )
        showPanel { [weak self] in
            guard let self, self.mode == .apps else { return }
            self.appPanel.present()
            DiagLog.log("panel", "app 面板上屏：按键后 \(Self.elapsedMs(since: self.sessionStartedAt))ms")
            self.tracePanelVisibility()
            // 面板已显示 = 用户在浏览，后台预取其余应用窗口，抹平「首次切到某图标才枚举」的延迟
            self.prewarmWindows()
        }
    }

    /// 后台读 Dock 角标（AX 可跨线程，避免卡首按），主线程更新缓存与面板视图
    private func refreshDockBadges() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let badges = DockBadgeService.badgeByTitle()
            DispatchQueue.main.async {
                guard let self, self.isAppSwitcherUIActive else { return }
                self.dockBadges = badges
                self.appPanel.updateBadges(self.switcherApps.map { badges[$0.name] })
            }
        }
    }

    /// 枚举 app 窗口并按窗口 MRU 排序；前台 app 的 MRU 可能过期（前台期间内部切窗无通知），
    /// 先刷新快照对齐 z-order 的最新状态
    private func currentWindows(for app: NSRunningApplication) -> [WindowItem] {
        if app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            windowMRU.snapshot(app)
        }
        let windows = windowMRU.ordered(WindowListService.windows(of: app), pid: app.processIdentifier)
        DiagLog.log("mru-order", "\(app.localizedName ?? "?"): "
            + windows.map { "\"\($0.title)\"" }.joined(separator: " "))
        return windows
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

    /// 激活即最近使用：pid 冒泡到 MRU 最前
    private func noteAppActivation(_ pid: pid_t) {
        appMRU.removeAll { $0 == pid }
        appMRU.insert(pid, at: 0)
    }

    /// 按 MRU 重排应用列表；未进入 MRU 的应用（本会话未激活过）按 z-order 原序附在后面
    private func mruOrdered(_ apps: [SwitcherApp]) -> [SwitcherApp] {
        guard !appMRU.isEmpty else { return apps }
        var picked = Set<pid_t>()
        var ordered: [SwitcherApp] = []
        for pid in appMRU {
            if let app = apps.first(where: { $0.app.processIdentifier == pid }) {
                ordered.append(app)
                picked.insert(pid)
            }
        }
        return ordered + apps.filter { !picked.contains($0.app.processIdentifier) }
    }

    // MARK: apps 模式操作

    private func moveApp(by delta: Int) {
        let count = switcherApps.count
        guard count > 0 else { return }
        focusApp(at: ((appIndex + delta) % count + count) % count)
    }

    /// 高亮到某应用并刷新其窗口列表：立即用已缓存窗口渲染（未加载则先空），
    /// AX 枚举一律交给防抖后台加载，绝不在主线程同步枚举——否则下拉列表首次显示会卡顿。
    /// 方向键与鼠标悬停共用这一条非阻塞路径，手感一致
    private func focusApp(at index: Int) {
        guard switcherApps.indices.contains(index) else { return }
        appIndex = index
        windowIndex = 0
        appPanel.selectApp(index: appIndex,
                           windows: switcherApps[appIndex].windows,
                           selectedWindow: windowIndex)
        scheduleWindowLoad(at: index)
    }

    /// 停在某应用短暂停顿后才加载其窗口：连续按方向键时不断取消重排，
    /// 只有真正停下的那个应用会触发一次后台 AX 枚举
    private func scheduleWindowLoad(at index: Int) {
        windowLoadWork?.cancel()
        guard switcherApps.indices.contains(index), !switcherApps[index].windowsLoaded else { return }
        let work = DispatchWorkItem { [weak self] in self?.loadWindowsInBackground(at: index) }
        windowLoadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    /// 后台做重的 AX 窗口枚举，完成后回主线程刷新（防抖触发，用于方向键 / 悬停切换）
    private func loadWindowsInBackground(at index: Int) {
        guard switcherApps.indices.contains(index), !switcherApps[index].windowsLoaded else { return }
        let app = switcherApps[index].app
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = WindowListService.windows(of: app)
            DispatchQueue.main.async { self?.applyLoadedWindows(raw, pid: pid, app: app) }
        }
    }

    /// 后台枚举结果写回主线程状态与面板：仍在 apps 模式、目标仍在且未加载才生效。
    /// MRU 快照/排序只在主线程（其状态只在主线程改）
    private func applyLoadedWindows(_ raw: [WindowItem], pid: pid_t, app: NSRunningApplication) {
        guard isAppSwitcherUIActive,
              let i = switcherApps.firstIndex(where: { $0.app.processIdentifier == pid }),
              !switcherApps[i].windowsLoaded else { return }
        // 前台 app 的 z 序快照对齐（读 CGWindowList，快）
        if pid == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            windowMRU.snapshot(app)
        }
        let ordered = windowMRU.ordered(raw, pid: pid)
        switcherApps[i].windows = ordered
        switcherApps[i].windowsLoaded = true
        if appIndex == i {
            appPanel.selectApp(index: i, windows: ordered, selectedWindow: windowIndex)
        }
    }

    /// 面板显示后在后台预取所有尚未加载的应用窗口：等用户悬停 / 方向键切到某应用时
    /// 多半已缓存，下拉列表首次显示即时。低优先级 + 顺序链式（一次只枚举一个），
    /// 避免一次性对所有应用发起 AX 调用形成风暴；每步在主线程校验仍在浏览，会话结束即止
    private func prewarmWindows() {
        prewarmNext(switcherApps.indices.filter { !switcherApps[$0].windowsLoaded })
    }

    private func prewarmNext(_ queue: [Int]) {
        guard isAppSwitcherUIActive, let index = queue.first else { return }
        let rest = Array(queue.dropFirst())
        guard switcherApps.indices.contains(index), !switcherApps[index].windowsLoaded else {
            prewarmNext(rest)
            return
        }
        let app = switcherApps[index].app
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raw = WindowListService.windows(of: app)
            DispatchQueue.main.async {
                self?.applyLoadedWindows(raw, pid: pid, app: app)
                self?.prewarmNext(rest)
            }
        }
    }

    private func moveWindow(by delta: Int) {
        guard switcherApps.indices.contains(appIndex) else { return }
        let windows = switcherApps[appIndex].windows
        guard !windows.isEmpty else { return }

        let count = windows.count
        // 未选窗口时首个方向键进入选择：向下选第一项，向上选最后一项
        let base = windowIndex ?? (delta > 0 ? -1 : count)
        let index = ((base + delta) % count + count) % count
        windowIndex = index
        appPanel.selectWindow(index: index)
    }

    /// 窗口列表惰性加载：只在应用首次被高亮时做 AX 枚举，保证首按 cmd+tab 的响应速度
    private func loadWindows(at index: Int) {
        guard switcherApps.indices.contains(index), !switcherApps[index].windowsLoaded else { return }
        switcherApps[index].windows = currentWindows(for: switcherApps[index].app)
        switcherApps[index].windowsLoaded = true
    }

    private func pickApp(at index: Int) {
        guard mode == .apps, switcherApps.indices.contains(index) else { return }
        appIndex = index
        // 点击图标 = 应用级提交，不预设窗口
        windowIndex = nil
        loadWindows(at: index)
        commitSelection()
    }

    /// 鼠标悬停图标：只移动高亮，不提交（与方向键共用非阻塞加载路径，首次悬停不再卡）
    private func hoverApp(at index: Int) {
        guard isAppSwitcherUIActive, switcherApps.indices.contains(index), index != appIndex else { return }
        focusApp(at: index)
    }

    private func pickWindow(at index: Int) {
        guard mode == .apps, switcherApps.indices.contains(appIndex),
              switcherApps[appIndex].windows.indices.contains(index) else { return }
        windowIndex = index
        commitSelection()
    }

    private func hoverWindow(at index: Int) {
        guard isAppSwitcherUIActive else { return }
        windowIndex = index
        // 同步面板高亮，否则悬停无视觉反馈
        appPanel.selectWindow(index: index)
    }

    // MARK: windows 模式操作

    /// 立即切到列表第 index 项：激活 + 循环栈旋转（目标到队首、刚用过的沉底）+ 高亮同步。
    /// cmd+` 的首次按键、后续每次按键、↑↓、点击行都收敛到这一条路径
    private func activateWindowItem(at index: Int) {
        guard mode == .windows, items.indices.contains(index), let app = targetApp else { return }
        let item = items[index]
        selection = index
        activatedWindowIndex = index
        windowPanel.select(index: index)
        DiagLog.log("activate-window", "\"\(item.title)\" idx=\(index) "
            + "id=\(item.cgWindowID.map(String.init) ?? "nil")")
        // 目标窗口可能尚不可见（最小化/跨 Space），失活快照看不到，激活时立即记入 MRU
        windowMRU.rotate(items, to: index, pid: app.processIdentifier)
        WindowActivator.activate(item, app: app)
    }

    /// 前进 / 后退一格并立即切换：cmd+` 不再有「只移动高亮、松开 Cmd 才提交」的两段式
    private func stepWindow(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        activateWindowItem(at: ((selection + delta) % count + count) % count)
    }

    /// 点击窗口行：立即切到该窗口并收起面板（一次点击 = 一次完整选择）
    private func pickWindowItem(at index: Int) {
        guard mode == .windows, items.indices.contains(index) else { return }
        activateWindowItem(at: index)
        endSelection()
    }

    /// 鼠标悬停窗口行：只移动光标不切换，下一次 cmd+` / ↑↓ 从这里继续
    private func hoverWindowItem(at index: Int) {
        guard mode == .windows, items.indices.contains(index) else { return }
        selection = index
    }

    // MARK: 提交与收尾

    /// cmd+tab 的提交（松开 Cmd 生效）。
    /// windows 模式（cmd+`）是立即切换：键盘每次按键已在 activateWindowItem 里切过，
    /// 但鼠标悬停只移光标不切换——松开时要把悬停高亮的那个窗口补上，否则「悬停后松开」什么也不会发生
    private func commitSelection() {
        if mode == .windows {
            if selection != activatedWindowIndex {
                activateWindowItem(at: selection)
            }
            endSelection()
            return
        }
        guard mode == .apps, switcherApps.indices.contains(appIndex) else {
            endSelection()
            return
        }
        // 提交是一次性动作：若目标应用的窗口还没（异步）加载完，此处同步补一次，
        // 保证按窗口 MRU 首窗提交，而不是退化成应用级激活
        loadWindows(at: appIndex)
        let target = switcherApps[appIndex]
        let window = windowIndex.flatMap {
            target.windows.indices.contains($0) ? target.windows[$0] : nil
        }
        endSelection()
        DiagLog.log("commit", "apps → \(target.name)(\(target.app.processIdentifier)) "
            + "windowIdx=\(windowIndex.map(String.init) ?? "nil") window=\"\(window?.title ?? "nil")\" "
            + "id=\(window?.cgWindowID.map(String.init) ?? "nil")")
        if let window {
            // 显式选了窗口：窗口级激活，不做组提升（其他窗口保持原位）
            windowMRU.noteFocus(window, pid: target.app.processIdentifier)
            WindowActivator.activate(window, app: target.app)
        } else {
            // 未选窗口：应用级激活，优先调出 MRU 第一（面板列表第一行）的窗口；
            // 最小化窗口不指定（原生 cmd+tab 不恢复最小化），交系统决策
            let preferred = target.windows.first { !$0.isMinimized }
            if let preferred {
                windowMRU.noteFocus(preferred, pid: target.app.processIdentifier)
            }
            WindowActivator.activateApp(target.app, preferred: preferred)
        }
    }

    private func cancelSelection() {
        guard mode != nil else { return }
        endSelection()
    }

    private func endSelection() {
        mode = nil
        modeTrigger = nil
        items = []
        activatedWindowIndex = nil
        targetApp = nil
        switcherApps = []
        scrollAccumulator = 0
        modifierWatchTimer?.invalidate()
        modifierWatchTimer = nil
        panelShowWork?.cancel()
        panelShowWork = nil
        windowLoadWork?.cancel()
        windowLoadWork = nil
        stallWatchTimer?.invalidate()
        stallWatchTimer = nil
        stopOutsideClickMonitor()
        windowPanel.dismiss()
        appPanel.dismiss()
        // swallowedKeyUps 不在此清空：被吞 keyDown 的物理按键可能仍按着，
        // 其 keyUp 必须继续吞掉，否则系统会收到孤儿释放事件
    }

    /// modifier 状态兜底：面板的正常关闭由松开修饰键的 flagsChanged 驱动；
    /// 该事件丢失（tap 异常）时轮询发现触发键的修饰键已物理松开才收起。
    /// 用户按住修饰键长时间浏览不主动取消（旧 30s 硬超时已移除）；
    /// 无修饰的功能键触发没有可松开的修饰键，提交由 keyUp 负责，无需轮询
    private func startTimeout() {
        guard let trigger = modeTrigger, !trigger.modifiers.isEmpty else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.modifierWatchInterval,
                                         repeats: true) { [weak self] _ in
            guard let self, self.mode != nil, let trigger = self.modeTrigger,
                  !CGEventSource.flagsState(.combinedSessionState)
                      .intersection(Shortcut.modifierMask)
                      .isSuperset(of: trigger.modifiers)
            else { return }
            self.cancelSelection()
        }
        modifierWatchTimer = timer
    }

    // MARK: 面板外点击取消

    /// 全局监听面板外的鼠标点击（global monitor 只收本应用之外的事件，
    /// 点击面板自身不会触发），点击即取消切换
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.mode != nil else { return }
            self.cancelSelection()
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
