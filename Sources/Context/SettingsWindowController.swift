import AppKit

/// 设置窗口：应用第一个普通 NSWindow。分组行布局（标题 + 右侧控件 + 发丝线），
/// 背景复用 Theme 的玻璃/毛玻璃；单实例、关闭仅 orderOut（isReleasedWhenClosed = false）
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private static let windowWidth: CGFloat = 440
    private static let contentInsets = NSEdgeInsets(top: 36, left: 16, bottom: 18, right: 16)

    private let updaterManager: UpdaterManager
    private let eventTapManager: EventTapManager
    private let isAccessibilityGranted: () -> Bool

    // 开关引用：refreshFromSources 时回写当前值（偏好可能被其他入口改动）
    private lazy var delayedPanelSwitch = makeSwitch(isOn: Settings.delayedPanel) { Settings.delayedPanel = $0 }
    private lazy var glassSwitch = makeSwitch(isOn: Settings.glassDisabled) { [weak self] isOn in
        Settings.glassDisabled = isOn
        // 面板每次显示都会重建背景；设置窗口本身也要跟上，否则要重启应用才变
        self?.rebuildBackground()
    }
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
    private lazy var loginItemSwitch = makeSwitch(isOn: loginItemManager.state == .enabled) { [weak self] isOn in
        self?.applyLoginItem(isOn)
    }
    private var loginItemRow: SettingsControlRow?
    private var loginItemsButtonRow: SettingsControlRow?

    // 布局支撑
    private weak var contentContainer: NSView?
    private var contentStack: NSStackView?
    private var stackBottomConstraint: NSLayoutConstraint?
    private var materialViews: [NSView] = []
    // 行 → 其上方的发丝线：动态隐藏行时分隔线要一起隐藏
    private var rowSeparators: [ObjectIdentifier: NSView] = [:]

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
    }

    func windowDidResignKey(_ notification: Notification) {
        // 用户点到别的应用：放弃本次录制——绝不能留着全局吞键
        cancelAllRecordings()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // 窗口存续期间外部状态可能已变（刚授权辅助功能、在系统设置里批准了登录项），回来时同步
        refreshFromSources()
        updateWindowSize()
    }

    // MARK: - 内容

    private func buildContent() {
        guard let window else { return }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 300))
        // 背景必须先装（installBackground 内部是 addSubview），内容后加才盖在材质之上；
        // 容器需带非零初始尺寸——材质层按当前 bounds 取 frame，之后靠 autoresizing 跟随窗口
        materialViews = Theme.installBackground(on: content, cornerRadius: 12)
        window.contentView = content
        contentContainer = content

        let sections = [
            makeSection(title: "行为", rows: [
                SettingsControlRow(title: "延迟显示面板（100ms）", subtitle: "快速点按不闪面板，按住超过 100ms 才出现", control: delayedPanelSwitch),
                SettingsControlRow(title: "不使用玻璃效果", subtitle: "面板观感异常时关闭液态玻璃，只保留毛玻璃", control: glassSwitch),
                SettingsControlRow(title: "诊断日志", subtitle: "排查问题时开启，写入 ~/Library/Logs/AppWindow.log", control: diagLogSwitch)
            ]),
            makeSection(title: "更新", rows: [
                SettingsControlRow(title: "自动检查更新", subtitle: "每天后台检查一次，发现新版本后提示安装", control: autoUpdateSwitch),
                SettingsControlRow(title: "参与测试版", subtitle: "接收预发布版本，可能不稳定", control: betaChannelSwitch)
            ]),
            makeSection(title: "通用", rows: makeLoginItemRows()),
            makeSection(title: "快捷键", rows: shortcutRows())
        ]

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        contentStack = stack

        // 显式把每个分组拉满宽度：NSStackView 的 .width 对齐不会把子视图拉伸到容器宽度，
        // 只有 intrinsic 宽度决定实际尺寸（窄分组会缩在中间，与相邻分组不对齐）
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let bottomConstraint = stack.bottomAnchor.constraint(
            equalTo: content.bottomAnchor, constant: -Self.contentInsets.bottom
        )
        stackBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            // 顶部留出红绿灯按钮的空间
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.contentInsets.top),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.contentInsets.left),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.contentInsets.right),
            bottomConstraint
        ])

        updateWindowSize()
    }

    /// 按当前内容重算窗口高度：动态显示/隐藏的行（登录项审批引导）会改变所需高度，
    /// 只在构建时算一次会触发 Auto Layout 约束冲突。
    /// 做法：临时放开底部约束让 stack 收缩到内容高度，量完再恢复
    private func updateWindowSize() {
        guard let window, let contentContainer, let contentStack else { return }
        stackBottomConstraint?.isActive = false
        contentContainer.layoutSubtreeIfNeeded()
        let requiredHeight = contentStack.frame.height
        stackBottomConstraint?.isActive = true
        window.setContentSize(NSSize(
            width: Self.windowWidth,
            height: requiredHeight + Self.contentInsets.top + Self.contentInsets.bottom
        ))
    }

    /// 玻璃开关切换后重建窗口背景（材质层是新 addSubview 到顶部的，需把内容栈重新抬到最上层）
    private func rebuildBackground() {
        guard let contentContainer else { return }
        for view in materialViews {
            view.removeFromSuperview()
        }
        materialViews = Theme.installBackground(on: contentContainer, cornerRadius: 12)
        if let contentStack {
            contentContainer.addSubview(contentStack, positioned: .above, relativeTo: nil)
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
            // 失败回弹到真实状态；常见原因：应用不在「应用程序」文件夹（如 DMG 内直接运行）
            DiagLog.log("login-item", "设置失败: \(error)")
            loginItemSwitch.state = loginItemManager.state == .enabled ? .on : .off
            loginItemRow?.setSubtitle("设置失败：\(error.localizedDescription)", color: .systemRed)
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
        let state = loginItemManager.state
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
        #endif
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
        glassSwitch.state = Settings.glassDisabled ? .on : .off
        diagLogSwitch.state = DiagLog.isEnabled ? .on : .off
        autoUpdateSwitch.state = updaterManager.automaticallyChecksForUpdates ? .on : .off
        betaChannelSwitch.state = Settings.betaChannel ? .on : .off
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

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
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
