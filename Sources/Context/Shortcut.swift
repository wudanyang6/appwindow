import AppKit
import Carbon.HIToolbox

/// 切换器触发键：keyCode 是物理键位（跨键盘布局稳定），modifiers 只承载 ⌘⌥⌃⇧。
/// 入口用精确匹配（避免与另一个触发键的修饰组合互相吞并），
/// 模式内用宽松匹配（对齐原生「按住修饰键后随便加键」的手感）
struct Shortcut: Hashable {
    var keyCode: UInt16
    var modifiers: CGEventFlags

    // CGEventFlags（OptionSet）未合成 Hashable，手工按 rawValue 实现（冲突检测需要 Set 去重）
    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    /// 只认四类修饰键；caps lock / fn / 小键盘位一律忽略
    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    static let defaultAppSwitcher = Shortcut(keyCode: UInt16(kVK_Tab), modifiers: .maskCommand)
    static let defaultWindowSwitcher = Shortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .maskCommand)

    // F1–F20 的 keycode 不连续（F1=122、F3=99…），必须显式列举；数组顺序即显示编号
    private static let functionKeyCodes: [UInt16] = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4), UInt16(kVK_F5),
        UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8), UInt16(kVK_F9), UInt16(kVK_F10),
        UInt16(kVK_F11), UInt16(kVK_F12), UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15),
        UInt16(kVK_F16), UInt16(kVK_F17), UInt16(kVK_F18), UInt16(kVK_F19), UInt16(kVK_F20)
    ]

    /// 入口匹配：修饰键必须完全一致（多余的 Opt/Ctrl 不算命中，
    /// 否则两个触发键的修饰组合会互相吞并）
    func matchesEntry(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && flags.intersection(Self.modifierMask) == modifiers
    }

    /// 模式内匹配：基础修饰键仍按住即可，允许额外修饰键
    func matchesInMode(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && flags.intersection(Self.modifierMask).isSuperset(of: modifiers)
    }

    /// 反向 = 基础修饰键 + Shift；基础键含 Shift 会被校验拒绝，因此反向始终无歧义
    var reversed: Shortcut {
        Shortcut(keyCode: keyCode, modifiers: modifiers.union(.maskShift))
    }

    var isFunctionKey: Bool {
        Self.functionKeyCodes.contains(keyCode)
    }

    /// 单键合法性：至少一个修饰键，或无修饰的功能键。
    /// 裸字母/数字/标点会被 tap 全局吞掉（等于全局禁用该键），裸 Tab/Space/方向键破坏输入，
    /// 一律拒绝；功能键不参与文本输入，可安全无修饰
    var validationError: ShortcutValidationError? {
        if modifiers.contains(.maskShift) { return .shiftInBase }
        if keyCode == UInt16(kVK_Escape) { return .reservedKey }
        if modifiers.isEmpty && !isFunctionKey { return .missingModifier }
        return nil
    }

    /// 显示串：修饰键按 ⌃⌥⇧⌘ 顺序 + 键名
    var displayString: String {
        var result = ""
        if modifiers.contains(.maskControl) { result += "⌃" }
        if modifiers.contains(.maskAlternate) { result += "⌥" }
        if modifiers.contains(.maskShift) { result += "⇧" }
        if modifiers.contains(.maskCommand) { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    // MARK: - 键名显示

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "␣",
        UInt16(kVK_Return): "↩",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟"
    ]

    // 兜底键名：UCKeyTranslate 取不到时（如极端输入源环境）覆盖常见 ANSI 键
    private static let fallbackKeyNames: [UInt16: String] = [
        UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_ANSI_Minus): "-",
        UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Slash): "/"
    ]

    private static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let index = functionKeyCodes.firstIndex(of: keyCode) { return "F\(index + 1)" }
        return printableKeyName(for: keyCode) ?? fallbackKeyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// 可打印键名：用 ASCII 布局翻译——中文等输入法激活时当前输入源常无布局数据，
    /// 且快捷键显示本来就该按物理布局字符展示
    private static func printableKeyName(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// 触发键校验失败原因；message 直接给录制控件展示
enum ShortcutValidationError: Equatable {
    case missingModifier
    case shiftInBase
    case reservedKey
    case sameKeyCode
    case chordCollision

    var message: String {
        switch self {
        case .missingModifier:
            return "至少需要一个修饰键（⌘⌃⌥），功能键可单独使用"
        case .shiftInBase:
            return "Shift 已用于反向切换，请换一个修饰键"
        case .reservedKey:
            return "Esc 已用于取消操作，不能作为触发键"
        case .sameKeyCode:
            return "两个切换器不能使用同一个按键"
        case .chordCollision:
            return "该组合与另一个快捷键冲突"
        }
    }

    /// 录制控件内联显示的短文案（完整说明见 message，用作 tooltip）
    var shortMessage: String {
        switch self {
        case .missingModifier:
            return "需要修饰键"
        case .shiftInBase:
            return "Shift 已被占用"
        case .reservedKey:
            return "Esc 不可用"
        case .sameKeyCode:
            return "按键重复"
        case .chordCollision:
            return "组合冲突"
        }
    }
}

/// 两个切换器的触发键组合；校验两个键之间不得冲突
struct ShortcutConfiguration: Equatable {
    var appSwitcher: Shortcut
    var windowSwitcher: Shortcut

    func validate() -> ShortcutValidationError? {
        if let error = appSwitcher.validationError { return error }
        if let error = windowSwitcher.validationError { return error }
        // 模式内按 keyCode 分派，同键不同修饰会产生歧义
        if appSwitcher.keyCode == windowSwitcher.keyCode { return .sameKeyCode }
        // 四个和弦（各自正向/反向）不得重复；当前 shiftInBase 规则下不可达，留作防御
        let chords = [appSwitcher, appSwitcher.reversed, windowSwitcher, windowSwitcher.reversed]
        if Set(chords).count != chords.count { return .chordCollision }
        return nil
    }
}

/// 触发键持久化：与 Settings 同款 UserDefaults 模式，defaults 可注入便于单测
enum ShortcutStore {
    enum Target {
        case appSwitcher
        case windowSwitcher
    }

    private static let appKeyCodeKey = "shortcutAppKeyCode"
    private static let appModifiersKey = "shortcutAppModifiers"
    private static let windowKeyCodeKey = "shortcutWindowKeyCode"
    private static let windowModifiersKey = "shortcutWindowModifiers"

    static func configuration(defaults: UserDefaults = .standard) -> ShortcutConfiguration {
        let configuration = ShortcutConfiguration(
            appSwitcher: load(
                keyCodeKey: appKeyCodeKey, modifiersKey: appModifiersKey,
                fallback: .defaultAppSwitcher, defaults: defaults
            ),
            windowSwitcher: load(
                keyCodeKey: windowKeyCodeKey, modifiersKey: windowModifiersKey,
                fallback: .defaultWindowSwitcher, defaults: defaults
            )
        )
        // 单项合法但相互冲突（同键/和弦重复）的损坏组合整体回退默认，避免快捷键静默失效
        if configuration.validate() == nil {
            return configuration
        }
        return ShortcutConfiguration(appSwitcher: .defaultAppSwitcher, windowSwitcher: .defaultWindowSwitcher)
    }

    static func set(_ shortcut: Shortcut, for target: Target, defaults: UserDefaults = .standard) {
        let keys = keys(for: target)
        defaults.set(Int(shortcut.keyCode), forKey: keys.keyCodeKey)
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: keys.modifiersKey)
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        for key in [appKeyCodeKey, appModifiersKey, windowKeyCodeKey, windowModifiersKey] {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load(
        keyCodeKey: String, modifiersKey: String, fallback: Shortcut, defaults: UserDefaults
    ) -> Shortcut {
        // 缺省用 object(forKey:) 判断：rawValue 0 不是合法触发键，不能与「未设置」混淆
        guard let keyCodeNumber = defaults.object(forKey: keyCodeKey) as? NSNumber,
              let modifiersNumber = defaults.object(forKey: modifiersKey) as? NSNumber else {
            return fallback
        }
        let shortcut = Shortcut(
            keyCode: keyCodeNumber.uint16Value,
            modifiers: CGEventFlags(rawValue: modifiersNumber.uint64Value)
        )
        // 损坏值回退默认，避免把应用卡在不可用键位上；
        // 修饰位必须只含四类修饰键——含 caps lock 等杂位时匹配恒假，同样视为损坏
        guard shortcut.validationError == nil,
              Shortcut.modifierMask.isSuperset(of: shortcut.modifiers) else {
            return fallback
        }
        return shortcut
    }

    private static func keys(for target: Target) -> (keyCodeKey: String, modifiersKey: String) {
        switch target {
        case .appSwitcher:
            return (appKeyCodeKey, appModifiersKey)
        case .windowSwitcher:
            return (windowKeyCodeKey, windowModifiersKey)
        }
    }
}
