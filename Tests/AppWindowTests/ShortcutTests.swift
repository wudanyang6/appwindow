import XCTest
import Carbon.HIToolbox
@testable import AppWindow

/// 触发键模型契约：精确入口匹配 / 宽松模式内匹配 / 反向 / 校验规则 / 持久化回退
final class ShortcutTests: XCTestCase {

    // MARK: - 默认值与匹配

    func testDefaultShortcuts() {
        XCTAssertEqual(Shortcut.defaultAppSwitcher.keyCode, UInt16(kVK_Tab))
        XCTAssertEqual(Shortcut.defaultAppSwitcher.modifiers, .maskCommand)
        XCTAssertEqual(Shortcut.defaultWindowSwitcher.keyCode, UInt16(kVK_ANSI_Grave))
        XCTAssertEqual(Shortcut.defaultWindowSwitcher.modifiers, .maskCommand)
    }

    func testEntryMatchRequiresExactModifiers() {
        let shortcut = Shortcut.defaultWindowSwitcher
        XCTAssertTrue(shortcut.matchesEntry(keyCode: UInt16(kVK_ANSI_Grave), flags: .maskCommand))
        // 多余修饰键不算命中（防两个触发键互相吞并）
        XCTAssertFalse(shortcut.matchesEntry(keyCode: UInt16(kVK_ANSI_Grave), flags: [.maskCommand, .maskAlternate]))
        // 缺修饰键不算命中
        XCTAssertFalse(shortcut.matchesEntry(keyCode: UInt16(kVK_ANSI_Grave), flags: []))
        // 无关位（caps lock）被忽略
        XCTAssertTrue(shortcut.matchesEntry(keyCode: UInt16(kVK_ANSI_Grave), flags: [.maskCommand, .maskAlphaShift]))
        // 键位不同不算命中
        XCTAssertFalse(shortcut.matchesEntry(keyCode: UInt16(kVK_Tab), flags: .maskCommand))
    }

    func testInModeMatchAllowsExtraModifiers() {
        let shortcut = Shortcut.defaultAppSwitcher
        XCTAssertTrue(shortcut.matchesInMode(keyCode: UInt16(kVK_Tab), flags: .maskCommand))
        XCTAssertTrue(shortcut.matchesInMode(keyCode: UInt16(kVK_Tab), flags: [.maskCommand, .maskAlternate]))
        // 基础修饰键丢失即不再命中
        XCTAssertFalse(shortcut.matchesInMode(keyCode: UInt16(kVK_Tab), flags: [.maskAlternate]))
    }

    func testReversedAddsShift() {
        let reversed = Shortcut.defaultAppSwitcher.reversed
        XCTAssertEqual(reversed.modifiers, [.maskCommand, .maskShift])
        XCTAssertTrue(reversed.matchesEntry(keyCode: UInt16(kVK_Tab), flags: [.maskCommand, .maskShift]))
        XCTAssertFalse(reversed.matchesEntry(keyCode: UInt16(kVK_Tab), flags: .maskCommand))
    }

    // MARK: - 校验

    func testSingleShortcutValidation() {
        // 裸字母拒绝
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: []).validationError,
            .missingModifier
        )
        // 功能键可无修饰（F1–F20 的 keycode 不连续，逐个覆盖）
        for keyCode in [kVK_F1, kVK_F6, kVK_F12, kVK_F20] {
            let shortcut = Shortcut(keyCode: UInt16(keyCode), modifiers: [])
            XCTAssertTrue(shortcut.isFunctionKey)
            XCTAssertNil(shortcut.validationError)
        }
        // Esc 拒绝
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_Escape), modifiers: .maskCommand).validationError,
            .reservedKey
        )
        // 基础键含 Shift 拒绝（Shift 保留作反向）
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_Tab), modifiers: [.maskCommand, .maskShift]).validationError,
            .shiftInBase
        )
    }

    func testConfigurationValidation() {
        let ok = ShortcutConfiguration(
            appSwitcher: .defaultAppSwitcher,
            windowSwitcher: .defaultWindowSwitcher
        )
        XCTAssertNil(ok.validate())

        // 同 keyCode 不同修饰：模式内按 keyCode 分派会歧义，拒绝
        let sameKey = ShortcutConfiguration(
            appSwitcher: Shortcut(keyCode: UInt16(kVK_Tab), modifiers: .maskCommand),
            windowSwitcher: Shortcut(keyCode: UInt16(kVK_Tab), modifiers: .maskAlternate)
        )
        XCTAssertEqual(sameKey.validate(), .sameKeyCode)

        // 非法单键优先报单键错误
        let invalidSingle = ShortcutConfiguration(
            appSwitcher: Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: []),
            windowSwitcher: .defaultWindowSwitcher
        )
        XCTAssertEqual(invalidSingle.validate(), .missingModifier)
    }

    // MARK: - 显示

    func testDisplayString() {
        XCTAssertEqual(Shortcut.defaultAppSwitcher.displayString, "⌘⇥")
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_Tab), modifiers: [.maskControl, .maskAlternate]).displayString,
            "⌃⌥⇥"
        )
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_F6), modifiers: []).displayString, "F6")
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_Tab), modifiers: [.maskCommand, .maskShift]).displayString,
            "⇧⌘⇥"
        )
    }

    // MARK: - 停用（设置里点「删除」）

    /// 停用态：不参与入口/模式匹配，校验放行，显示为「未设置」
    func testDisabledShortcutNeverMatches() {
        let disabled = Shortcut.disabled
        XCTAssertTrue(disabled.isDisabled)
        XCTAssertFalse(disabled.matchesEntry(keyCode: disabled.keyCode, flags: disabled.modifiers))
        XCTAssertFalse(disabled.matchesEntry(keyCode: UInt16(kVK_Tab), flags: .maskCommand),
                       "停用后任何按键都不应命中")
        XCTAssertFalse(disabled.matchesInMode(keyCode: UInt16(kVK_Tab), flags: .maskCommand))
        XCTAssertNil(disabled.validationError, "停用是合法状态，不该报「缺少修饰键」")
        XCTAssertEqual(disabled.displayString, "未设置")
    }

    /// 任一项停用就不存在跨键冲突：停用项不参与匹配，也不会挡着另一项
    func testDisabledEntrySkipsConflictChecks() {
        let configuration = ShortcutConfiguration(
            appSwitcher: .disabled,
            windowSwitcher: .defaultWindowSwitcher
        )
        XCTAssertNil(configuration.validate(), "停用项不该与另一项判冲突")

        let bothDisabled = ShortcutConfiguration(appSwitcher: .disabled, windowSwitcher: .disabled)
        XCTAssertNil(bothDisabled.validate(), "两项都停用也是合法配置")
    }

    /// 持久化：停用只翻标记位（键位保留），重新录制即解除；恢复默认回到默认键位
    func testStorePersistsDisabledFlag() {
        let suiteName = "ShortcutTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建测试用 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ShortcutStore.set(.disabled, for: .appSwitcher, defaults: defaults)
        XCTAssertTrue(ShortcutStore.configuration(defaults: defaults).appSwitcher.isDisabled)
        XCTAssertFalse(ShortcutStore.configuration(defaults: defaults).windowSwitcher.isDisabled,
                       "停用只影响目标项")

        // 重新录制：解除停用并落新键位
        let recorded = Shortcut(keyCode: UInt16(kVK_F6), modifiers: [])
        ShortcutStore.set(recorded, for: .appSwitcher, defaults: defaults)
        XCTAssertEqual(ShortcutStore.configuration(defaults: defaults).appSwitcher, recorded)

        // 恢复默认：回到默认键位且可用
        ShortcutStore.set(.disabled, for: .appSwitcher, defaults: defaults)
        ShortcutStore.resetToDefaults(defaults: defaults)
        XCTAssertEqual(ShortcutStore.configuration(defaults: defaults).appSwitcher, .defaultAppSwitcher)
    }

    // MARK: - 持久化

    func testStoreRoundTripAndFallbacks() {
        let suiteName = "ShortcutTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建测试用 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 缺省回退默认值
        XCTAssertEqual(
            ShortcutStore.configuration(defaults: defaults).appSwitcher,
            .defaultAppSwitcher
        )

        // 自定义值 round-trip
        let custom = Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [.maskControl, .maskAlternate])
        ShortcutStore.set(custom, for: .appSwitcher, defaults: defaults)
        XCTAssertEqual(ShortcutStore.configuration(defaults: defaults).appSwitcher, custom)

        // 损坏值（非法键位）读取时回退默认
        ShortcutStore.set(
            Shortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: []),
            for: .windowSwitcher,
            defaults: defaults
        )
        XCTAssertEqual(
            ShortcutStore.configuration(defaults: defaults).windowSwitcher,
            .defaultWindowSwitcher
        )

        // 恢复默认
        ShortcutStore.resetToDefaults(defaults: defaults)
        XCTAssertEqual(
            ShortcutStore.configuration(defaults: defaults),
            ShortcutConfiguration(appSwitcher: .defaultAppSwitcher, windowSwitcher: .defaultWindowSwitcher)
        )
    }
}
