import AppKit

/// 设置窗口：应用第一个普通 NSWindow。分组行布局（标题 + 右侧控件 + 发丝线），
/// 背景复用 Theme 的玻璃/毛玻璃；单实例、关闭仅 orderOut（isReleasedWhenClosed = false）
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private static let windowWidth: CGFloat = 560
    // 顶栏（红绿灯 + Tab 切换）高度与文档内边距
    private static let headerHeight: CGFloat = 44
    private static let contentInsets = NSEdgeInsets(top: 12, left: 16, bottom: 18, right: 16)

    private let updaterManager: UpdaterManager
    private let eventTapManager: EventTapManager
    private let isAccessibilityGranted: () -> Bool

    // 开关引用：refreshFromSources 时回写当前值（偏好可能被其他入口改动）
    private lazy var delayedPanelSwitch = makeSwitch(isOn: Settings.delayedPanel) { Settings.delayedPanel = $0 }
    private lazy var glassModeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            labels: ["Regular", "Clear", "关闭"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(glassModeChanged(_:))
        )
        control.controlSize = .small
        control.selectedSegment = Self.segmentIndex(for: Settings.glassMode)
        return control
    }()
    private lazy var glassBlurControl: GlassBlurControl = {
        let control = GlassBlurControl()
        control.onChange = { [weak self] in
            // 设置窗口自身背景立即重建；两个切换面板在下次显示时生效
            self?.rebuildBackground()
        }
        return control
    }()
    private lazy var diagLogSwitch = makeSwitch(isOn: DiagLog.isEnabled) { DiagLog.isEnabled = $0 }
    private lazy var autoUpdateSwitch = makeSwitch(isOn: updaterManager.automaticallyChecksForUpdates) { [weak self] isOn in
        self?.updaterManager.automaticallyChecksForUpdates = isOn
    }
    private lazy var betaChannelSwitch = makeSwitch(isOn: Settings.betaChannel) { [weak self] isOn in
        Settings.betaChannel = isOn
        self?.updaterManager.betaChannelDidChange()
    }
    private var switchHandlers: [ObjectIdentifier: (Bool) -> Void] = [:]

    // 快捷键
    private var appSwitcherRecorder: ShortcutRecorderView?
    private var windowSwitcherRecorder: ShortcutRecorderView?
    private var shortcutHintLabel: NSTextField?

    // 开机自启动
    private let loginItemManager = LoginItemManager()
    // 初始状态先给 off：status 是慢 XPC（实测 300ms+），窗口构建时同步读会卡首次打开；
    // show() 的异步刷新会在 ~300ms 内纠正显示
    private lazy var loginItemSwitch = makeSwitch(isOn: false) { [weak self] isOn in
        self?.applyLoginItem(isOn)
    }
    private var loginItemRow: SettingsControlRow?
    private var loginItemsButtonRow: SettingsControlRow?

    // 布局支撑
    private weak var contentContainer: NSView?
    private weak var contentScrollView: NSScrollView?
    private var contentStack: NSStackView?
    private var stackBottomConstraint: NSLayoutConstraint?
    private var materialViews: [NSView] = []
    // 行 → 其上方的发丝线：动态隐藏行时分隔线要一起隐藏
    private var rowSeparators: [ObjectIdentifier: NSView] = [:]
    // Tab 切换（顶部分段控件）与「每个 Tab 归属哪些分组」
    private var tabSegmentedControl: NSSegmentedControl?
    private var tabSections: [[NSView]] = []

    // 面板几何参数
    private var tuningControls: [TuningControl] = []
    private var previewViews: [PanelPreviewView] = []
    private var advancedSection: NSView?
    private var advancedToggle: NSButton?

    init(
        updaterManager: UpdaterManager,
        eventTapManager: EventTapManager,
        isAccessibilityGranted: @escaping () -> Bool
    ) {
        self.updaterManager = updaterManager
        self.eventTapManager = eventTapManager
        self.isAccessibilityGranted = isAccessibilityGranted

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AppWindow 设置"
        // 透明标题栏 + 隐藏标题：内容（含玻璃背景）延伸到顶部，仅红绿灯浮在上面
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // ARC 下必须 false：否则关闭即释放，再次打开崩溃
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        // 记住上次位置；没有记录时居中（默认位置在屏幕左下角）
        if !window.setFrameUsingName("AppWindowSettings") {
            window.center()
        }
        window.setFrameAutosaveName("AppWindowSettings")
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 打开设置：先同步各控件当前值再前置。
    /// accessory 应用用 activate + makeKeyAndOrderFront 前置（关于面板同款先例），
    /// 不切 .regular，避免与更新 UI 的激活策略切换互相覆盖
    func show() {
        refreshFromSources()
        updateWindowSize()
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            window.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelAllRecordings()
        eventTapManager.endPreview()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 用户点到别的应用：放弃本次录制——绝不能留着全局吞键
        cancelAllRecordings()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 窗口存续期间外部状态可能已变（刚授权辅助功能、在系统设置里批准了登录项），回来时同步；
        // 点击设置窗口也意味着预览该收了
        eventTapManager.endPreview()
        refreshFromSources()
        updateWindowSize()
    }

    // MARK: - 内容

    private func buildContent() {
        guard let window else { return }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 300))
        // 背景必须先装（installBackground 内部是 addSubview），内容后加才盖在材质之上；
        // 容器需带非零初始尺寸——材质层按当前 bounds 取 frame，之后靠 autoresizing 跟随窗口。
        // 设置窗口是普通窗口、内容自持约束，取 .materials 即可（内容不装入 contentHost）
        materialViews = Theme.installBackground(on: content, cornerRadius: 12).materials
        window.contentView = content
        contentContainer = content

        // 顶部 Tab 切换：固定不随内容滚动（内容超过小屏时下面滚动）
        let tabControl = NSSegmentedControl(
            labels: ["通用", "更新", "快捷键", "面板与图标"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(switchTab(_:))
        )
        tabControl.selectedSegment = 0
        tabControl.controlSize = .small
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabControl)
        tabSegmentedControl = tabControl

        // 内容（20 项几何 + 全部开关）在小屏上会超过可见高度：放进滚动容器，窗口高度按屏幕封顶
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        contentScrollView = scrollView
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // 纵向滚动：文档宽度跟随可视宽度（不横向滚动）
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        // Tab 归属：通用（行为开关 + 开机自启动）/ 更新 / 快捷键 / 面板与图标（几何 + 高级折叠）
        let generalSection = makeSection(title: "通用", rows: [
            SettingsControlRow(title: "延迟显示面板（100ms）", subtitle: "快速点按不闪面板，按住超过 100ms 才出现", control: delayedPanelSwitch),
            SettingsControlRow(title: "玻璃效果", subtitle: "面板背景材质；观感异常时切 Clear 或关闭", control: glassModeControl),
            SettingsControlRow(title: "毛玻璃垫层强度", subtitle: "玻璃之下的额外模糊层；0% = 关闭（更通透），越高模糊越强", control: glassBlurControl),
            SettingsControlRow(title: "诊断日志", subtitle: "排查问题时开启，写入 ~/Library/Logs/AppWindow.log", control: diagLogSwitch)
        ] + makeLoginItemRows())
        let updateSection = makeSection(title: "更新", rows: [
            SettingsControlRow(title: "自动检查更新", subtitle: "每天后台检查一次，发现新版本后提示安装", control: autoUpdateSwitch),
            SettingsControlRow(title: "参与测试版", subtitle: "接收预发布版本，可能不稳定", control: betaChannelSwitch)
        ])
        let shortcutSection = makeSection(title: "快捷键", rows: shortcutRows())
        let previewSection = makePreviewSection()
        let geometrySection = makeGeometrySection()
        let advancedGeometrySection = makeAdvancedSection()

        let sections = [generalSection, updateSection, shortcutSection, previewSection, geometrySection, advancedGeometrySection]
        tabSections = [
            [generalSection], [updateSection], [shortcutSection],
            [previewSection, geometrySection, advancedGeometrySection]
        ]

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        contentStack = stack

        // 显式把每个分组拉满宽度：NSStackView 的 .width 对齐不会把子视图拉伸到容器宽度，
        // 只有 intrinsic 宽度决定实际尺寸（窄分组会缩在中间，与相邻分组不对齐）
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let bottomConstraint = stack.bottomAnchor.constraint(
            equalTo: documentView.bottomAnchor, constant: -Self.contentInsets.bottom
        )
        stackBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            // 顶部留出红绿灯按钮的空间
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Self.contentInsets.top),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Self.contentInsets.left),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -Self.contentInsets.right),
            bottomConstraint
        ])

        updateSectionVisibility()
        updateWindowSize()
    }

    /// 按当前内容重算窗口高度：动态显示/隐藏的行（登录项引导、高级折叠）会改变所需高度；
    /// 内容不足时窗口贴合内容，超出时按屏幕可见高度封顶（滚动容器接管）
    private func updateWindowSize() {
        guard let window, let contentContainer, let contentStack else { return }
        stackBottomConstraint?.isActive = false
        contentContainer.layoutSubtreeIfNeeded()
        let requiredHeight = contentStack.frame.height
        stackBottomConstraint?.isActive = true

        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let desired = Self.headerHeight + requiredHeight + Self.contentInsets.top + Self.contentInsets.bottom
        window.setContentSize(NSSize(
            width: Self.windowWidth,
            height: min(desired, screenHeight * 0.9)
        ))
    }

    // MARK: - Tab 切换

    @objc private func switchTab(_ sender: NSSegmentedControl) {
        updateSectionVisibility()
        updateWindowSize()
        scrollToTop()
    }

    /// 按当前 Tab 与「高级折叠」状态统一计算每个分组的显隐
    private func updateSectionVisibility() {
        let selected = tabSegmentedControl?.selectedSegment ?? 0
        let advancedOn = advancedToggle?.state == .on
        for (index, group) in tabSections.enumerated() {
            for section in group {
                if section === advancedSection {
                    // 高级分组：既要属于当前 Tab，又要折叠开关打开
                    section.isHidden = !(index == selected && advancedOn)
                } else {
                    section.isHidden = index != selected
                }
            }
        }
    }

    private func scrollToTop() {
        guard let contentScrollView else { return }
        contentScrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        contentScrollView.reflectScrolledClipView(contentScrollView.contentView)
    }

    /// 玻璃开关切换后重建窗口背景。材质层由 installBackground 直接 addSubview 到顶层，
    /// 重建后必须重排到**所有兄弟视图的最底层**（relativeTo nil = 所有兄弟之下）：
    /// 只放到滚动视图之下会盖住位于材质与滚动视图之间的 Tab 切换控件
    private func rebuildBackground() {
        guard let contentContainer else { return }
        for view in materialViews {
            view.removeFromSuperview()
        }
        materialViews = Theme.installBackground(on: contentContainer, cornerRadius: 12).materials
        for view in materialViews {
            contentContainer.addSubview(view, positioned: .below, relativeTo: nil)
        }
    }

    private func shortcutRows() -> [NSView] {
        let appRecorder = ShortcutRecorderView(eventTapManager: eventTapManager)
        appRecorder.onBeginRequested = { [weak self] recorder in self?.beginRecording(recorder) }
        appRecorder.onCaptured = { [weak self] shortcut in self?.applyCaptured(shortcut, target: .appSwitcher) }
        appSwitcherRecorder = appRecorder

        let windowRecorder = ShortcutRecorderView(eventTapManager: eventTapManager)
        windowRecorder.onBeginRequested = { [weak self] recorder in self?.beginRecording(recorder) }
        windowRecorder.onCaptured = { [weak self] shortcut in self?.applyCaptured(shortcut, target: .windowSwitcher) }
        windowSwitcherRecorder = windowRecorder

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetShortcuts))
        resetButton.controlSize = .small

        let hint = NSTextField(labelWithString: "需要辅助功能权限才能录制快捷键")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .systemOrange
        shortcutHintLabel = hint

        return [
            SettingsControlRow(title: "应用切换器", subtitle: "按住修饰键选择，松开完成切换", control: appRecorder),
            SettingsControlRow(title: "窗口切换器", subtitle: "每按一次立即切换下一个窗口", control: windowRecorder),
            SettingsControlRow(title: "恢复默认快捷键", control: resetButton),
            hint
        ]
    }

    // MARK: - 面板几何

    /// 内嵌实时预览：Cmd+Tab 与 Cmd+` 的缩小版外观，随几何参数即时重建
    private func makePreviewSection() -> NSView {
        let appPreview = PanelPreviewView(mode: .appSwitcher)
        let windowPreview = PanelPreviewView(mode: .windowSwitcher)
        previewViews = [appPreview, windowPreview]

        let column = NSStackView(views: [
            makePreviewCaption("Cmd+Tab 应用切换器"),
            appPreview,
            makePreviewCaption("Cmd+` 窗口面板"),
            windowPreview
        ])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 6

        return makeSection(title: "预览（随参数实时更新）", rows: [column])
    }

    private func makePreviewCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        // 显式左对齐：标签在 .width 对齐的栈里会被拉伸，避免跟随默认 alignment 靠右
        label.alignment = .left
        return label
    }

    /// 几何参数变化：重建内嵌预览 + 刷新屏幕上的全尺寸预览（后者未开启时为空操作）
    private func refreshPreviews() {
        previewViews.forEach { $0.rebuild() }
        updateWindowSize()
        eventTapManager.refreshLivePreview()
    }

    private func makeGeometrySection() -> NSView {
        var rows: [NSView] = Tuning.common.map { makeTuningRow($0) }

        let previewAppButton = NSButton(title: "应用切换器", target: self, action: #selector(previewAppSwitcher))
        previewAppButton.controlSize = .small
        let previewWindowButton = NSButton(title: "窗口列表", target: self, action: #selector(previewWindowSwitcher))
        previewWindowButton.controlSize = .small
        let previewButtons = NSStackView(views: [previewAppButton, previewWindowButton])
        previewButtons.orientation = .horizontal
        previewButtons.spacing = 6
        rows.append(SettingsControlRow(
            title: "全尺寸预览",
            subtitle: "在屏幕上弹出真实面板（随参数实时更新）；Esc / 点击面板 / 点击其他应用结束",
            control: previewButtons
        ))

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetTuning))
        resetButton.controlSize = .small
        rows.append(SettingsControlRow(title: "恢复全部几何默认值", control: resetButton))

        let advancedToggle = NSButton(checkboxWithTitle: "显示高级参数", target: self, action: #selector(toggleAdvanced(_:)))
        advancedToggle.controlSize = .small
        self.advancedToggle = advancedToggle
        rows.append(SettingsControlRow(title: "高级参数", control: advancedToggle))

        return makeSection(title: "面板几何", rows: rows)
    }

    private func makeAdvancedSection() -> NSView {
        let section = makeSection(title: "高级几何", rows: Tuning.advanced.map { makeTuningRow($0) })
        section.isHidden = true
        advancedSection = section
        return section
    }

    private func makeTuningRow(_ spec: TuningSpec) -> SettingsControlRow {
        let control = TuningControl(spec: spec)
        // 参数变化即重建内嵌预览并刷新全尺寸预览
        control.onChange = { [weak self] in self?.refreshPreviews() }
        tuningControls.append(control)
        return SettingsControlRow(title: spec.title, subtitle: spec.subtitle, control: control)
    }

    @objc private func toggleAdvanced(_ sender: NSButton) {
        updateSectionVisibility()
        updateWindowSize()
    }

    @objc private func resetTuning() {
        Tuning.resetAll()
        tuningControls.forEach { $0.refresh() }
        refreshPreviews()
    }

    @objc private func previewAppSwitcher() {
        eventTapManager.startLivePreview(.appSwitcher)
    }

    @objc private func previewWindowSwitcher() {
        eventTapManager.startLivePreview(.windowSwitcher)
    }

    // MARK: - 开机自启动

    private func makeLoginItemRows() -> [NSView] {
        let row = SettingsControlRow(
            title: "开机自启动",
            subtitle: "登录时自动启动 AppWindow",
            control: loginItemSwitch
        )
        loginItemRow = row

        let openButton = NSButton(title: "打开登录项设置", target: self, action: #selector(openLoginItemsSettings))
        openButton.controlSize = .small
        let buttonRow = SettingsControlRow(title: "被系统拦截时", control: openButton)
        buttonRow.isHidden = true
        loginItemsButtonRow = buttonRow

        return [row, buttonRow]
    }

    private func applyLoginItem(_ enabled: Bool) {
        #if DEBUG
        return
        #else
        do {
            try loginItemManager.setEnabled(enabled)
        } catch {
            // 失败回弹；常见原因：应用不在「应用程序」文件夹（如 DMG 内直接运行）。
            // 真实状态由随后的异步读取纠正（status 是慢 XPC，不在主线程同步读）
            DiagLog.log("login-item", "设置失败: \(error)")
            loginItemRow?.setSubtitle("设置失败：\(error.localizedDescription)", color: .systemRed)
            refreshLoginItemRow()
            return
        }
        refreshLoginItemRow()
        #endif
    }

    private func refreshLoginItemRow() {
        #if DEBUG
        loginItemSwitch.state = .off
        loginItemSwitch.isEnabled = false
        loginItemRow?.setSubtitle("调试构建不可用", color: .secondaryLabelColor)
        setRow(loginItemsButtonRow, hidden: true)
        #else
        // SMAppService.status 是同步 XPC，实测单次 290–580ms；windowDidBecomeKey（Cmd+Tab
        // 循环中设置窗口重获焦点时）都会走这里，同步读会把主线程卡出明显掉帧。
        // 后台读、主线程回写；短暂显示旧值可接受
        let manager = loginItemManager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = manager.state
            DispatchQueue.main.async {
                self?.applyLoginItemState(state)
            }
        }
        #endif
    }

    private static func segmentIndex(for mode: GlassMode) -> Int {
        switch mode {
        case .regular: return 0
        case .clear: return 1
        case .off: return 2
        }
    }

    @objc private func glassModeChanged(_ sender: NSSegmentedControl) {
        let mode: GlassMode
        switch sender.selectedSegment {
        case 1: mode = .clear
        case 2: mode = .off
        default: mode = .regular
        }
        Settings.glassMode = mode
        // 面板每次显示都会重建背景；设置窗口本身也要跟上，否则要重启应用才变
        rebuildBackground()
    }

    private func applyLoginItemState(_ state: LoginItemState) {
        let showsApproval = state == .requiresApproval
        let visibilityChanged = (loginItemsButtonRow?.isHidden ?? true) == showsApproval

        loginItemSwitch.state = state == .enabled ? .on : .off
        switch state {
        case .enabled, .notRegistered:
            loginItemRow?.setSubtitle("登录时自动启动 AppWindow")
            setRow(loginItemsButtonRow, hidden: true)
        case .requiresApproval:
            loginItemRow?.setSubtitle("需在「系统设置 → 通用 → 登录项」中允许", color: .systemOrange)
            setRow(loginItemsButtonRow, hidden: false)
        case .notFound, .unavailable:
            loginItemRow?.setSubtitle("当前环境不支持自启动", color: .systemRed)
            setRow(loginItemsButtonRow, hidden: true)
        }
        // 审批引导行的显隐变化会改变内容高度（异步读取晚于窗口打开/聚焦）
        if visibilityChanged {
            updateWindowSize()
        }
    }

    /// 隐藏行时连同其上方发丝线一起隐藏（否则会留下悬空的线）
    private func setRow(_ row: SettingsControlRow?, hidden: Bool) {
        guard let row else { return }
        row.isHidden = hidden
        rowSeparators[ObjectIdentifier(row)]?.isHidden = hidden
    }

    @objc private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 快捷键录制协调

    /// 同一时刻只允许一个控件录制：先取消另一个，再开始
    private func beginRecording(_ recorder: ShortcutRecorderView) {
        guard isAccessibilityGranted() else { return }
        for other in [appSwitcherRecorder, windowSwitcherRecorder] where other !== recorder {
            other?.cancelRecording()
        }
        recorder.startRecording()
    }

    /// 捕获后的落库：单键合法性已在录制会话里校验，这里做跨键冲突校验
    private func applyCaptured(_ shortcut: Shortcut, target: ShortcutStore.Target) {
        var configuration = ShortcutStore.configuration()
        switch target {
        case .appSwitcher:
            configuration.appSwitcher = shortcut
        case .windowSwitcher:
            configuration.windowSwitcher = shortcut
        }

        guard let error = configuration.validate() else {
            ShortcutStore.set(shortcut, for: target)
            refreshShortcutRows()
            return
        }

        // 冲突：不落库；先结束录制（恢复键盘透传）再回显错误
        let recorder = target == .appSwitcher ? appSwitcherRecorder : windowSwitcherRecorder
        recorder?.cancelRecording()
        recorder?.showConflictError(error)
    }

    @objc private func resetShortcuts() {
        cancelAllRecordings()
        ShortcutStore.resetToDefaults()
        refreshShortcutRows()
    }

    private func refreshShortcutRows() {
        let configuration = ShortcutStore.configuration()
        appSwitcherRecorder?.setShortcut(configuration.appSwitcher)
        windowSwitcherRecorder?.setShortcut(configuration.windowSwitcher)

        let granted = isAccessibilityGranted()
        shortcutHintLabel?.isHidden = granted
        appSwitcherRecorder?.setRecordingEnabled(granted)
        windowSwitcherRecorder?.setRecordingEnabled(granted)
    }

    private func cancelAllRecordings() {
        appSwitcherRecorder?.cancelRecording()
        windowSwitcherRecorder?.cancelRecording()
    }

    // MARK: - 刷新

    private func refreshFromSources() {
        delayedPanelSwitch.state = Settings.delayedPanel ? .on : .off
        glassModeControl.selectedSegment = Self.segmentIndex(for: Settings.glassMode)
        glassBlurControl.refresh()
        diagLogSwitch.state = DiagLog.isEnabled ? .on : .off
        autoUpdateSwitch.state = updaterManager.automaticallyChecksForUpdates ? .on : .off
        betaChannelSwitch.state = Settings.betaChannel ? .on : .off
        tuningControls.forEach { $0.refresh() }
        previewViews.forEach { $0.rebuild() }
        refreshLoginItemRow()
        refreshShortcutRows()
    }

    // MARK: - 分组布局与行组件

    private func makeSwitch(isOn: Bool, onChange: @escaping (Bool) -> Void) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(switchToggled(_:))
        switchHandlers[ObjectIdentifier(toggle)] = onChange
        return toggle
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        switchHandlers[ObjectIdentifier(sender)]?(sender.state == .on)
    }

    /// 分组：小标题 + 行堆叠（行间发丝线）。
    /// 行与分隔线都显式拉满宽度——依赖 NSStackView 对齐只会按 intrinsic 宽度排布，窄行会缩进
    private func makeSection(title: String, rows: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                rowsStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                rowSeparators[ObjectIdentifier(row)] = separator
            }
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        let section = NSStackView(views: [header, rowsStack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        rowsStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }
}

/// 设置行：标题（+ 可动态更新的副标题）在左，任意控件在右
private final class SettingsControlRow: NSView {
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(title: String, subtitle: String? = nil, control: NSView) {
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        // 标签默认压缩阻力 required：长副标题会把窗口最小宽度撑大，允许压缩（截断）保住固定窗宽
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil

        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        left.addArrangedSubview(titleLabel)
        left.addArrangedSubview(subtitleLabel)

        addSubview(left)
        addSubview(control)
        left.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            left.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            left.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 动态副标题（登录项状态等），空串隐藏
    func setSubtitle(_ text: String, color: NSColor = .secondaryLabelColor) {
        subtitleLabel.stringValue = text
        subtitleLabel.textColor = color
        subtitleLabel.isHidden = text.isEmpty
    }
}

/// 几何参数控件：滑杆（粗调）+ 数值标签（双击恢复默认）+ 步进器（细调）；
/// 拖动期间连续写 UserDefaults（内存缓存，无 IO 压力）
private final class TuningControl: NSView {
    private let spec: TuningSpec
    /// 值变化（拖动/步进/恢复默认）回调：设置窗口用它重建预览
    var onChange: (() -> Void)?
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let stepper = NSStepper()
    private let resetButton = NSButton()

    init(spec: TuningSpec) {
        self.spec = spec
        super.init(frame: .zero)

        slider.minValue = Double(spec.value.range.lowerBound)
        slider.maxValue = Double(spec.value.range.upperBound)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.toolTip = "双击恢复默认"
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(labelDoubleClicked))
        // 手势默认单击即触发；必须显式要求双击，否则单击数值标签会静默重置参数
        doubleClick.numberOfClicksRequired = 2
        valueLabel.addGestureRecognizer(doubleClick)

        stepper.minValue = Double(spec.value.range.lowerBound)
        stepper.maxValue = Double(spec.value.range.upperBound)
        stepper.increment = Double(spec.value.step)
        stepper.valueWraps = false
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        // 单项还原默认：非默认值时才可用
        resetButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "恢复默认")
        resetButton.isBordered = false
        resetButton.controlSize = .small
        resetButton.toolTip = "恢复默认"
        resetButton.target = self
        resetButton.action = #selector(resetClicked)

        for view in [slider, valueLabel, stepper, resetButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            slider.widthAnchor.constraint(equalToConstant: 150),
            valueLabel.widthAnchor.constraint(equalToConstant: 56),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            resetButton.leadingAnchor.constraint(equalTo: stepper.trailingAnchor, constant: 6),
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            resetButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 从存储重读并回写三个控件（refreshFromSources / 恢复默认后调用）
    func refresh() {
        let value = spec.value.value
        slider.doubleValue = Double(value)
        stepper.doubleValue = Double(value)
        valueLabel.stringValue = spec.formattedValue
        resetButton.isEnabled = !spec.value.isDefault
    }

    @objc private func sliderChanged() {
        apply(slider.doubleValue)
    }

    @objc private func stepperChanged() {
        apply(stepper.doubleValue)
    }

    @objc private func labelDoubleClicked() {
        resetClicked()
    }

    @objc private func resetClicked() {
        spec.value.reset()
        refresh()
        onChange?()
    }

    private func apply(_ raw: Double) {
        // 整数项吸附（滑杆给的是连续值）
        let newValue = spec.value.isInteger ? raw.rounded() : raw
        spec.value.store(CGFloat(newValue))
        refresh()
        onChange?()
    }
}

/// 垫层强度控件：0–100% 滑杆 + 百分比数值；0% 即关闭（Theme 不装配垫层）。
/// 拖动期间连续写 UserDefaults，onChange 由设置窗口重建自身背景即时呈现
private final class GlassBlurControl: NSView {
    var onChange: (() -> Void)?
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right

        for view in [slider, valueLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            slider.widthAnchor.constraint(equalToConstant: 150),
            valueLabel.widthAnchor.constraint(equalToConstant: 44),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 从存储重读并回写控件（refreshFromSources 调用；偏好可能被旧键迁移等外部因素改动）
    func refresh() {
        let strength = Settings.glassUnderBlurStrength
        slider.doubleValue = strength
        valueLabel.stringValue = "\(Int((strength * 100).rounded()))%"
    }

    @objc private func sliderChanged() {
        Settings.glassUnderBlurStrength = slider.doubleValue
        refresh()
        onChange?()
    }
}

/// 滚动容器里的文档视图：flipped 让内容从顶部开始排列
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
