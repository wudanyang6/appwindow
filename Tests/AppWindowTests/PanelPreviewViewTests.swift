import XCTest
import AppKit
@testable import AppWindow

/// 内嵌面板预览契约：随几何参数重建（尺寸变化可观测）
final class PanelPreviewViewTests: XCTestCase {

    override func tearDown() {
        Tuning.iconSizeMax.reset()
        Tuning.iconSizeMin.reset()
        Tuning.rowHeight.reset()
        Tuning.panelWidth.reset()
        super.tearDown()
    }

    func testAppSwitcherPreviewFollowsIconSize() {
        let preview = PanelPreviewView(mode: .appSwitcher)
        preview.layoutSubtreeIfNeeded()
        let baseWidth = preview.contentSize.width
        XCTAssertGreaterThan(baseWidth, 0)

        Tuning.iconSizeMax.store(220)
        preview.rebuild()
        XCTAssertGreaterThan(preview.contentSize.width, baseWidth, "图标最大尺寸变大，预览内容应变宽")
    }

    func testAppSwitcherPreviewFollowsRowHeight() {
        let preview = PanelPreviewView(mode: .appSwitcher)
        preview.layoutSubtreeIfNeeded()
        let baseHeight = preview.intrinsicContentSize.height

        Tuning.rowHeight.store(60)
        preview.rebuild()
        XCTAssertGreaterThan(preview.intrinsicContentSize.height, baseHeight, "行高变大，预览应变高")
    }

    func testWindowSwitcherPreviewFollowsPanelWidthAndRowHeight() {
        let preview = PanelPreviewView(mode: .windowSwitcher)
        let base = preview.contentSize
        XCTAssertGreaterThan(base.width, 0)
        XCTAssertGreaterThan(base.height, 0)

        Tuning.panelWidth.store(900)
        Tuning.rowHeight.store(60)
        preview.rebuild()
        XCTAssertGreaterThan(preview.contentSize.width, base.width, "面板宽度变大，预览应变宽")
        XCTAssertGreaterThan(preview.contentSize.height, base.height, "行高变大，预览应变高")
    }
}
