import XCTest
import AppKit
@testable import AppWindow

/// 设置窗口布局回归：分组必须撑满容器宽度。
/// 曾出过的问题：依赖 NSStackView 的 .width 对齐，窄分组按 intrinsic 宽度缩在中间，
/// 与相邻分组左右不对齐（快捷键分组曾整体缩进）
final class SettingsLayoutTests: XCTestCase {

    func testSectionsFillContainerWidth() throws {
        let controller = SettingsWindowController(
            updaterManager: UpdaterManager(),
            eventTapManager: EventTapManager(panel: SwitchPanel()),
            isAccessibilityGranted: { true }
        )
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let stack = try XCTUnwrap(
            content.subviews.compactMap { $0 as? NSStackView }.first,
            "内容栈应存在"
        )
        XCTAssertEqual(stack.arrangedSubviews.count, 4, "应有 行为/更新/通用/快捷键 四个分组")

        for section in stack.arrangedSubviews {
            XCTAssertEqual(
                section.frame.width, stack.frame.width, accuracy: 0.5,
                "每个分组都应撑满容器宽度（不得按 intrinsic 宽度缩进）"
            )
        }
    }
}
