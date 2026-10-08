import XCTest
@testable import AppWindow

/// 几何参数存储层契约：clamp / 损坏回退 / 重置 / 目录表不变量
final class TuningValueTests: XCTestCase {

    /// 独立 suite，不污染真实域
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TuningValueTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("无法创建测试用 UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    func testMissingValueFallsBackToDefault() {
        withDefaults { defaults in
            let value = TuningValue(key: "k", default: 42, range: 0...100, defaults: defaults)
            XCTAssertEqual(value.value, 42)
            XCTAssertTrue(value.isDefault)
        }
    }

    func testOutOfRangeValuesAreClampedOnRead() {
        withDefaults { defaults in
            let value = TuningValue(key: "k", default: 42, range: 0...100, defaults: defaults)
            defaults.set(999, forKey: "k")
            XCTAssertEqual(value.value, 100)
            defaults.set(-5, forKey: "k")
            XCTAssertEqual(value.value, 0)
        }
    }

    /// 字符串等损坏值必须回退默认（NSNumber 判型），而不是被 double(forKey:) 当成 0
    func testCorruptedValueFallsBackToDefault() {
        withDefaults { defaults in
            let value = TuningValue(key: "k", default: 42, range: 0...100, defaults: defaults)
            defaults.set("abc", forKey: "k")
            XCTAssertEqual(value.value, 42)
        }
    }

    func testSetterClamps() {
        withDefaults { defaults in
            let value = TuningValue(key: "k", default: 42, range: 0...100, defaults: defaults)
            value.store(500)
            XCTAssertEqual(value.value, 100)
            value.store(-1)
            XCTAssertEqual(value.value, 0)
        }
    }

    func testResetRestoresDefault() {
        withDefaults { defaults in
            let value = TuningValue(key: "k", default: 42, range: 0...100, defaults: defaults)
            value.store(77)
            value.reset()
            XCTAssertEqual(value.value, 42)
            XCTAssertTrue(value.isDefault)
        }
    }

    func testIntValueRounds() {
        withDefaults { defaults in
            let value = TuningValue(key: "k", default: 0, range: 0...100, isInteger: true, defaults: defaults)
            value.store(33.6)
            XCTAssertEqual(value.intValue, 34)
        }
    }

    // MARK: - 目录表不变量

    func testCatalogKeysAreUnique() {
        let keys = Tuning.all.map { $0.value.key }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testCatalogDefaultsAreInsideRanges() {
        for spec in Tuning.all {
            XCTAssertTrue(
                spec.value.range.contains(spec.value.defaultValue),
                "\(spec.value.key) 默认值不在范围内"
            )
        }
    }

    /// 默认值锚点：锁死当前设计基线，防无意改动。
    /// 改造时全部等于旧硬编码常量，之后按实测反馈有意调整过（见各行注释）；
    /// 2026-10 的一批来自系统 cmd+tab 实拍校准（像素测量：节距 95pt、底板 90pt、侧边留白 36pt 等）
    func testCatalogDefaultsMatchLegacyConstants() {
        let expected: [String: CGFloat] = [
            "tuning.iconSizeMax": 90,         // 系统校准：154 → 90（图标槽位；+间距 5 = 节距 95）
            "tuning.rowHeight": 34,
            "tuning.maxListRows": 8,
            "tuning.panelWidth": 520,
            "tuning.listFontSize": 13,
            "tuning.iconGap": 5,              // 系统校准：12 → 5
            "tuning.cornerRadius": 40,        // 有意调整：26 → 40（对齐系统观感）
            "tuning.listCornerRadius": 16,
            "tuning.iconSizeMin": 0,
            "tuning.iconInset": 28,           // 有意调整：24 → 36 → 44 → 50 → 28（先加大，再按观感收到 28）
            "tuning.panelSideMargin": 87,     // 有意调整：系统校准 48 → 36，再按观感放到 87
            "tuning.backdropBlurRadius": 0,   // 新增：面板背后真高斯模糊半径，0 = 关闭
            "tuning.panelVerticalPadding": 4, // 新增：图标托盘上下留白（比原观感高 8pt）
            "tuning.panelGap": 6,
            "tuning.edgeInset": 8,
            "tuning.listWidthMin": 180,
            "tuning.listWidthMax": 360,
            "tuning.listWidthPadding": 54,
            "tuning.nameFontSize": 13,        // 系统校准：12 → 13（实测名称字高 ≈ 13pt）
            "tuning.nameGap": 1,
            "tuning.nameBottomInset": 6,      // 系统校准：5 → 6（面板下缘留白对齐系统 ≈ 20pt）
            "tuning.heightRatio": 0.70
        ]
        XCTAssertEqual(Tuning.all.count, expected.count)
        for spec in Tuning.all {
            guard let legacy = expected[spec.value.key] else {
                return XCTFail("未登记的参数 key: \(spec.value.key)")
            }
            XCTAssertEqual(spec.value.defaultValue, legacy, spec.value.key)
        }
    }

    func testCatalogGroupCounts() {
        XCTAssertEqual(Tuning.common.count, 9)
        XCTAssertEqual(Tuning.advanced.count, 13)
    }

    func testFormattedValue() {
        withDefaults { defaults in
            let ratioValue = TuningValue(key: "r", default: 0.70, range: 0.30...0.95, step: 0.05, defaults: defaults)
            let ratio = TuningSpec(value: ratioValue, title: "", subtitle: nil, group: .advanced, unit: "%", displayScale: 100)
            XCTAssertEqual(ratio.formattedValue, "70%")

            let ptValue = TuningValue(key: "p", default: 154, range: 72...256, defaults: defaults)
            let pt = TuningSpec(value: ptValue, title: "", subtitle: nil, group: .common, unit: "pt", displayScale: 1)
            XCTAssertEqual(pt.formattedValue, "154pt")
        }
    }
}
