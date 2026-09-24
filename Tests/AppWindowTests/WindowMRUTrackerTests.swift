import XCTest
import ApplicationServices
@testable import AppWindow

/// 窗口级 MRU 三段排序：MRU 命中（按最近序）→ 在屏未命中 → 离屏，
/// 冒泡更新与 pid/windowID 匹配语义。用占位 AXUIElement 构造 WindowItem 夹具。
final class WindowMRUTrackerTests: XCTestCase {

    private func item(_ id: CGWindowID?, onScreen: Bool = true, title: String = "w") -> WindowItem {
        WindowItem(axWindow: AXUIElementCreateApplication(0),
                   title: title, isMinimized: false, cgWindowID: id, isOnScreen: onScreen)
    }

    func testEmptyMRUKeepsOriginalOrder() {
        let tracker = WindowMRUTracker()
        let ordered = tracker.ordered([item(1), item(2), item(3)], pid: 42)
        XCTAssertEqual(ordered.map(\.cgWindowID), [1, 2, 3])
    }

    func testNoteFocusBubblesToFront() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(3), pid: 42)
        let ordered = tracker.ordered([item(1), item(2), item(3)], pid: 42)
        XCTAssertEqual(ordered.first?.cgWindowID, 3)
    }

    func testThreeTierOrdering() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(2), pid: 42)   // 较早
        tracker.noteFocus(item(1), pid: 42)   // 最近 → 排 2 前
        // 输入乱序：未命中在屏(3)、未命中离屏(4)、命中(1)、命中(2)
        let windows = [item(3, onScreen: true), item(4, onScreen: false), item(1), item(2)]
        let ordered = tracker.ordered(windows, pid: 42)
        XCTAssertEqual(ordered.map(\.cgWindowID), [1, 2, 3, 4])
    }

    func testDifferentPidNeverMatches() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(1), pid: 42)
        let ordered = tracker.ordered([item(2), item(1)], pid: 99) // 同 id 不同 pid
        XCTAssertEqual(ordered.map(\.cgWindowID), [2, 1]) // 全未命中，保持原序
    }

    func testNilWindowIDNeverMatches() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(1), pid: 42)
        let ordered = tracker.ordered([item(nil), item(1)], pid: 42)
        XCTAssertEqual(ordered.first?.cgWindowID, 1) // 命中的 1 冒到最前
    }

    func testReFocusMovesToFront() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(1), pid: 42)
        tracker.noteFocus(item(2), pid: 42)   // 现序 2,1
        tracker.noteFocus(item(1), pid: 42)   // 1 重新冒到最前 → 1,2
        let ordered = tracker.ordered([item(2), item(1)], pid: 42)
        XCTAssertEqual(ordered.map(\.cgWindowID), [1, 2])
    }
}
