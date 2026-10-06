import XCTest
import AppKit
@testable import AppWindow

/// 指标层契约：读取随配置变化、槽位公式夹取、角标等比、跨项约束在读取处化解
final class PanelMetricsTests: XCTestCase {

    override func tearDown() {
        // 写的是测试进程自己的 defaults 域；清理保证用例互不干扰
        Tuning.iconSizeMax.reset()
        Tuning.iconSizeMin.reset()
        Tuning.rowHeight.reset()
        Tuning.panelWidth.reset()
        Tuning.listWidthMin.reset()
        Tuning.listWidthMax.reset()
        super.tearDown()
    }

    func testMetricsFollowConfiguration() {
        Tuning.iconSizeMax.store(200)
        Tuning.rowHeight.store(60)
        Tuning.panelWidth.store(640)
        XCTAssertEqual(SwitcherMetrics.iconSizeMax, 200)
        XCTAssertEqual(SwitcherMetrics.rowHeight, 60)
        XCTAssertEqual(PanelMetrics.rowHeight, 60)
        XCTAssertEqual(PanelMetrics.width, 640)
    }

    func testIconSlotSizeClamps() {
        // 默认配置：应用少时封顶 154
        XCTAssertEqual(SwitcherMetrics.iconSlotSize(count: 3, availableWidth: 1000), 154)
        // 应用多时按宽度均分缩小
        let many = SwitcherMetrics.iconSlotSize(count: 40, availableWidth: 1000)
        XCTAssertLessThan(many, 154)
        XCTAssertGreaterThan(many, 0)
        // 配置下限生效
        Tuning.iconSizeMin.store(40)
        XCTAssertEqual(SwitcherMetrics.iconSlotSize(count: 40, availableWidth: 1000), 40)
        // 下限不允许超过上限（跨项约束在读取处化解）
        Tuning.iconSizeMin.store(200)
        Tuning.iconSizeMax.store(120)
        XCTAssertEqual(SwitcherMetrics.iconSizeMin, 120)
    }

    func testBadgeHeightScalesWithConfiguredMax() {
        // 默认 iconSizeMax = 154 时与改造前逐像素一致
        XCTAssertEqual(SwitcherMetrics.badgeHeight(forIconSize: 154), 48)
        XCTAssertEqual(SwitcherMetrics.badgeHeight(forIconSize: 77), 24)
        XCTAssertEqual(SwitcherMetrics.badgeHeight(forIconSize: 30), 24)
        // 基准跟随配置的最大尺寸
        Tuning.iconSizeMax.store(100)
        XCTAssertEqual(SwitcherMetrics.badgeHeight(forIconSize: 100), 48)
        XCTAssertEqual(SwitcherMetrics.badgeHeight(forIconSize: 50), 24)
    }

    func testListWidthBoundsResolveCrossConstraint() {
        Tuning.listWidthMin.store(400)
        Tuning.listWidthMax.store(300)
        XCTAssertEqual(SwitcherMetrics.listWidthMin, 300)
        XCTAssertEqual(SwitcherMetrics.listWidthMax, 300)
    }
}
