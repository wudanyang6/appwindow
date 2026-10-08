import AppKit
import Carbon.HIToolbox

/// 录制会话：录制期间由事件 tap 吞掉键盘并直接回调本会话（不走 NSApp 事件派发），
/// 因此录制 Cmd+Tab 这类系统组合键时系统切换器不会叠加弹出。
/// 生命周期由录制控件管理：Esc / 捕获完成 / 关窗 / 失焦都会结束
final class ShortcutRecorderSession {

    var onModifiersChanged: ((CGEventFlags) -> Void)?
    var onCaptured: ((Shortcut) -> Void)?
    var onRejected: ((ShortcutValidationError) -> Void)?
    var onCancelled: (() -> Void)?
    /// 会话结束（无论取消还是捕获完成）都会回调，供宿主复位 UI 与解除 tap 拦截
    var onFinished: (() -> Void)?
    private(set) var isFinished = false

    private var pendingKeyUp: UInt16?
    // 录制期间被吞 keyDown 的键：只有这些键的 keyUp 才吞；
    // 录制开始前已按下的键（keyDown 已投递给前台 app）的 keyUp 必须放行，否则前台 app 会粘键
    private var swallowedKeys: Set<UInt16> = []

    /// 返回 true = 吞掉事件；flagsChanged 必须透传（保持系统修饰键状态同步）
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .keyDown:
            handleKeyDown(event)
            return true
        case .keyUp:
            return handleKeyUp(event)
        case .flagsChanged:
            onModifiersChanged?(event.flags)
            return false
        default:
            return false
        }
    }

    /// 外部取消（再次点击 / 关窗 / 失焦）
    func cancel() {
        finish(cancelled: true)
    }

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        swallowedKeys.insert(keyCode)

        // 按住不放的自动重复不算新的按键
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }

        // Esc 只用于取消，不参与录制
        if keyCode == UInt16(kVK_Escape) {
            finish(cancelled: true)
            return
        }

        // 修饰键自身没有 keyDown（走 flagsChanged），这里都是普通键
        let candidate = Shortcut(
            keyCode: keyCode,
            modifiers: event.flags.intersection(Shortcut.modifierMask)
        )
        if let error = candidate.validationError {
            // 单键非法：提示后继续录制，不结束会话
            onRejected?(error)
            return
        }
        pendingKeyUp = keyCode
        onCaptured?(candidate)
    }

    private func handleKeyUp(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        // 只吞录制期间确实按下过的键的 keyUp
        guard swallowedKeys.remove(keyCode) != nil else { return false }

        // 捕获的键释放后才算完整一次录制，避免残留按住状态影响后续按键
        if keyCode == pendingKeyUp {
            pendingKeyUp = nil
            finish(cancelled: false)
        }
        return true
    }

    private func finish(cancelled: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if cancelled {
            onCancelled?()
        }
        onFinished?()
    }
}

/// 触发键录制控件：点击开始录制（事件 tap 吞键并直投会话），
/// Esc / 再次点击 / 关窗 / 失焦取消；捕获合法组合后回调宿主做跨键校验并落库
final class ShortcutRecorderView: NSControl {

    /// 捕获到单键合法的组合；宿主做「与另一个切换器冲突」校验后落库并回写显示
    var onCaptured: ((Shortcut) -> Void)?
    /// 开始录制前通知宿主（宿主先取消另一个控件的录制，tap 同时只服务一个会话）
    var onBeginRequested: ((ShortcutRecorderView) -> Void)?

    private let eventTapManager: EventTapManager
    private let valueLabel = NSTextField(labelWithString: "")
    private var session: ShortcutRecorderSession?
    private var shortcut: Shortcut = .defaultAppSwitcher
    private var errorResetWork: DispatchWorkItem?
    private var recordingEnabled = true

    init(eventTapManager: EventTapManager) {
        self.eventTapManager = eventTapManager
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        valueLabel.alignment = .center
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        valueLabel.lineBreakMode = .byTruncatingTail
        addSubview(valueLabel)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 150),
            heightAnchor.constraint(equalToConstant: 26),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard recordingEnabled else { return }
        if isRecording {
            cancelRecording()
        } else {
            onBeginRequested?(self)
        }
    }

    var isRecording: Bool { session != nil }

    func setShortcut(_ shortcut: Shortcut) {
        self.shortcut = shortcut
        // 录制中不覆盖实时预览；会话结束后 onFinished 会用新值复位
        if !isRecording {
            updateAppearance()
        }
    }

    /// 辅助功能未授权时禁用（tap 未运行，录制收不到事件）
    func setRecordingEnabled(_ enabled: Bool) {
        recordingEnabled = enabled
        toolTip = enabled ? nil : "需要辅助功能权限才能录制快捷键"
        if !enabled {
            cancelRecording()
        }
        updateAppearance()
    }

    /// 宿主发现跨键冲突时回显（会话已由宿主取消）
    func showConflictError(_ error: ShortcutValidationError) {
        showError(error)
    }

    func startRecording() {
        guard session == nil, recordingEnabled else { return }
        let session = ShortcutRecorderSession()
        session.onModifiersChanged = { [weak self] flags in
            self?.showModifierPreview(flags)
        }
        session.onCaptured = { [weak self] shortcut in
            self?.onCaptured?(shortcut)
        }
        session.onRejected = { [weak self] error in
            self?.showError(error)
        }
        session.onFinished = { [weak self] in
            guard let self else { return }
            self.session = nil
            self.eventTapManager.endRecording()
            self.updateAppearance()
        }
        self.session = session
        eventTapManager.beginRecording(session)
        showRecordingState()
    }

    func cancelRecording() {
        session?.cancel()
    }

    // MARK: - 外观

    private func updateAppearance() {
        // 录制中不覆盖实时预览（捕获成功后等待 keyUp 期间由 onFinished 统一复位）
        guard !isRecording else { return }
        // 未授权录制、或该快捷键已停用（设置里点过「删除」）：都显示为灰态
        if !recordingEnabled || shortcut.isDisabled {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            valueLabel.textColor = .tertiaryLabelColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            valueLabel.textColor = .labelColor
        }
        valueLabel.stringValue = shortcut.displayString
    }

    private func showRecordingState() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.stringValue = "按下按键…"
    }

    /// 实时预览已按下的修饰键（完整键符等 keyDown 捕获后由宿主回写）
    private func showModifierPreview(_ flags: CGEventFlags) {
        guard isRecording else { return }
        let modifiers = flags.intersection(Shortcut.modifierMask)
        guard !modifiers.isEmpty else {
            valueLabel.stringValue = "按下按键…"
            return
        }
        var preview = ""
        if modifiers.contains(.maskControl) { preview += "⌃" }
        if modifiers.contains(.maskAlternate) { preview += "⌥" }
        if modifiers.contains(.maskShift) { preview += "⇧" }
        if modifiers.contains(.maskCommand) { preview += "⌘" }
        valueLabel.stringValue = preview + "…"
    }

    private func showError(_ error: ShortcutValidationError) {
        toolTip = error.message
        valueLabel.stringValue = error.shortMessage
        valueLabel.textColor = .systemRed
        errorResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.toolTip = self.recordingEnabled ? nil : "需要辅助功能权限才能录制快捷键"
            if self.isRecording {
                self.showRecordingState()
            } else {
                self.updateAppearance()
            }
        }
        errorResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
