import XCTest
import AppKit
@testable import AppWindow

/// 窗口列表滚动控制器的偏移数学：钳制、方向、ensureVisible 对齐。
/// 用哑 NSView 承载内容视图（不需要显示环境），只验证偏移计算。
final class ListScrollControllerTests: XCTestCase {

    private func makeController(total: Int, shown: Int,
                               rowHeight: CGFloat = 34) -> ListScrollController {
        let controller = ListScrollController()
        controller.attach(contents: [NSView()], rowHeight: rowHeight, total: total, shown: shown)
        return controller
    }

    func testMaxScrollAndInitialState() {
        let controller = makeController(total: 10, shown: 5) // 内容 340，视口 170
        XCTAssertEqual(controller.maxScroll, 170)
        XCTAssertEqual(controller.offset, 0)
        XCTAssertFalse(controller.hasMoreAbove)
        XCTAssertTrue(controller.hasMoreBelow)
    }

    func testContentFitsCannotScroll() {
        let controller = makeController(total: 3, shown: 5) // 内容 102 < 视口 170
        XCTAssertEqual(controller.maxScroll, 0)
        controller.scroll(by: -100)
        XCTAssertEqual(controller.offset, 0)
        XCTAssertFalse(controller.hasMoreAbove)
        XCTAssertFalse(controller.hasMoreBelow)
    }

    func testScrollNegatesDeltaAndClamps() {
        let controller = makeController(total: 10, shown: 5) // maxScroll 170
        controller.scroll(by: -50)                 // offset = 0 - (-50)
        XCTAssertEqual(controller.offset, 50)
        XCTAssertTrue(controller.hasMoreAbove)
        XCTAssertTrue(controller.hasMoreBelow)

        controller.scroll(by: -1000)               // 上溢钳到 maxScroll
        XCTAssertEqual(controller.offset, 170)
        XCTAssertFalse(controller.hasMoreBelow)

        controller.scroll(by: 1000)                // 下溢钳到 0
        XCTAssertEqual(controller.offset, 0)
    }

    func testOffsetChangedFiresOnlyOnChange() {
        let controller = makeController(total: 10, shown: 5)
        var count = 0
        controller.onOffsetChanged = { count += 1 }
        controller.scroll(by: -20)                 // 变化 → 回调
        controller.scroll(by: 0)                   // 偏移不变 → 不回调
        XCTAssertEqual(count, 1)
    }

    func testEnsureVisibleBringsRowIntoView() {
        let total = 10, shown = 5
        let rowHeight: CGFloat = 34
        let controller = makeController(total: total, shown: shown, rowHeight: rowHeight)
        let contentHeight = CGFloat(total) * rowHeight
        let clipHeight = CGFloat(shown) * rowHeight

        func rowVisible(_ index: Int) -> Bool {
            let rowY = CGFloat(total - 1 - index) * rowHeight
            let rowTop = rowY + rowHeight
            let visibleBottom = contentHeight - clipHeight - controller.offset
            let visibleTop = contentHeight - controller.offset
            return rowY >= visibleBottom - 0.01 && rowTop <= visibleTop + 0.01
        }

        controller.ensureVisible(index: total - 1, total: total) // 视觉最上
        XCTAssertTrue(rowVisible(total - 1))
        XCTAssertGreaterThanOrEqual(controller.offset, 0)
        XCTAssertLessThanOrEqual(controller.offset, controller.maxScroll)

        controller.ensureVisible(index: 0, total: total)         // 视觉最下
        XCTAssertTrue(rowVisible(0))
    }

    /// 行高可配置：maxScroll / ensureVisible 的数学与 attach 传入的行高同源
    func testNonDefaultRowHeight() {
        let total = 10, shown = 3
        let rowHeight: CGFloat = 60
        let controller = makeController(total: total, shown: shown, rowHeight: rowHeight)
        XCTAssertEqual(controller.rowHeight, rowHeight)
        XCTAssertEqual(controller.maxScroll, CGFloat(total - shown) * rowHeight)

        let contentHeight = CGFloat(total) * rowHeight
        let clipHeight = CGFloat(shown) * rowHeight
        func rowVisible(_ index: Int) -> Bool {
            let rowY = CGFloat(total - 1 - index) * rowHeight
            let rowTop = rowY + rowHeight
            let visibleBottom = contentHeight - clipHeight - controller.offset
            let visibleTop = contentHeight - controller.offset
            return rowY >= visibleBottom - 0.01 && rowTop <= visibleTop + 0.01
        }

        controller.ensureVisible(index: total - 1, total: total)
        XCTAssertTrue(rowVisible(total - 1))
        controller.ensureVisible(index: 0, total: total)
        XCTAssertTrue(rowVisible(0))
        XCTAssertLessThanOrEqual(controller.offset, controller.maxScroll)
    }

    /// 重新 attach（每次面板显示都会调用）刷新行高并重置偏移
    func testReattachRefreshesRowHeightAndResetsOffset() {
        let controller = makeController(total: 10, shown: 5, rowHeight: 34)
        controller.scroll(by: -50)
        XCTAssertEqual(controller.offset, 50)

        controller.attach(contents: [NSView()], rowHeight: 60, total: 10, shown: 5)
        XCTAssertEqual(controller.rowHeight, 60)
        XCTAssertEqual(controller.offset, 0)
        XCTAssertEqual(controller.maxScroll, CGFloat(5) * 60)
    }
}
