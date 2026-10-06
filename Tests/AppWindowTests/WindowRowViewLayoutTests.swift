import XCTest
import AppKit
@testable import AppWindow

/// 行视图自适应布局：默认行高与改造前逐像素一致；其他行高下居中且不越界
final class WindowRowViewLayoutTests: XCTestCase {

    private func makeRow(width: CGFloat, height: CGFloat, contentInset: CGFloat = 8,
                         fontSize: CGFloat = 13) -> WindowRowView {
        let row = WindowRowView(
            index: 0, icon: nil, title: "测试窗口标题",
            width: width, contentInset: contentInset,
            font: .systemFont(ofSize: fontSize), rowHeight: height,
            hoverGate: MouseHoverGate(),
            onHover: { _ in }, onClick: { _ in }
        )
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func iconFrame(of row: WindowRowView) -> NSRect? {
        row.subviews.compactMap { $0 as? NSImageView }.first?.frame
    }

    private func titleFrame(of row: WindowRowView) -> NSRect? {
        row.subviews.compactMap { $0 as? NSTextField }.first?.frame
    }

    /// 默认 34pt 行高下与改造前一致：图标 (inset+8, 8, 18, 18)、
    /// 标题 (inset+34, 9, width-2*inset-42, 18)（含 1pt 光学偏移的行盒锚定）
    func testDefaultRowHeightMatchesLegacyLayout() {
        let inset: CGFloat = 8
        let row = makeRow(width: 400, height: 34, contentInset: inset)

        XCTAssertEqual(iconFrame(of: row), NSRect(x: inset + 8, y: 8, width: 18, height: 18))
        guard let title = titleFrame(of: row) else {
            return XCTFail("缺少标题子视图")
        }
        XCTAssertEqual(title, NSRect(x: inset + 34, y: 9,
                                     width: 400 - inset * 2 - 42, height: 18))
    }

    func testAdaptiveLayoutAcrossRowHeights() {
        for height in [20.0, 34.0, 60.0, 80.0] as [CGFloat] {
            let row = makeRow(width: 400, height: height)
            guard let icon = iconFrame(of: row), let title = titleFrame(of: row) else {
                return XCTFail("缺少图标或标题子视图 @\(height)")
            }
            // 垂直居中（允许取整与 1pt 光学偏移）
            XCTAssertEqual(icon.midY, height / 2, accuracy: 1.0, "icon 未垂直居中 @\(height)")
            XCTAssertEqual(title.midY, height / 2, accuracy: 1.5, "title 未垂直居中 @\(height)")
            // 不越界
            XCTAssertGreaterThanOrEqual(icon.minY, 0)
            XCTAssertLessThanOrEqual(icon.maxY, height)
            XCTAssertGreaterThanOrEqual(title.minY, 0)
            XCTAssertLessThanOrEqual(title.maxY, height)
            XCTAssertLessThanOrEqual(title.maxX, 400)
        }
    }

    func testLargerFontStillFits() {
        let row = makeRow(width: 400, height: 60, fontSize: 18)
        guard let title = titleFrame(of: row) else {
            return XCTFail("缺少标题子视图")
        }
        XCTAssertLessThanOrEqual(title.maxY, 60)
        XCTAssertGreaterThan(title.height, 16)
    }

    /// 极端组合（大字号 + 最矮行）也不越出行边界
    func testExtremeFontAndRowHeightStayInsideBounds() {
        let row = makeRow(width: 400, height: 20, fontSize: 20)
        guard let title = titleFrame(of: row) else {
            return XCTFail("缺少标题子视图")
        }
        XCTAssertGreaterThanOrEqual(title.minY, 0)
        XCTAssertLessThanOrEqual(title.maxY, 20)
    }
}
