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

    // MARK: 循环栈旋转（cmd+` 每次按键都走这里）

    /// 切到目标窗口：目标及其之后的窗口保持相对序在前，目标之前的（刚用过的）沉到最下方
    func testRotateSinksWindowsBeforeTarget() {
        let tracker = WindowMRUTracker()
        let windows = [item(1), item(2), item(3), item(4)]
        tracker.rotate(windows, to: 1, pid: 42)
        XCTAssertEqual(tracker.ordered(windows, pid: 42).map(\.cgWindowID), [2, 3, 4, 1])
    }

    /// 跨会话连续前进：下一次的参考是上一次的结果，前进一格到 3 而不是回到 1
    func testRotateContinuesCycleAcrossSessions() {
        let tracker = WindowMRUTracker()
        let windows = [item(1), item(2), item(3), item(4)]
        tracker.rotate(windows, to: 1, pid: 42)
        let afterFirst = tracker.ordered(windows, pid: 42)
        XCTAssertEqual(afterFirst.map(\.cgWindowID), [2, 3, 4, 1])

        tracker.rotate(afterFirst, to: 1, pid: 42)
        XCTAssertEqual(tracker.ordered(windows, pid: 42).map(\.cgWindowID), [3, 4, 1, 2])
    }

    /// 目标是末项时整组循环位移（↑ / 跳转走同一条旋转规则）
    func testRotateWrapsWhenTargetIsLast() {
        let tracker = WindowMRUTracker()
        let windows = [item(1), item(2), item(3), item(4)]
        tracker.rotate(windows, to: 3, pid: 42)
        XCTAssertEqual(tracker.ordered(windows, pid: 42).map(\.cgWindowID), [4, 1, 2, 3])
    }

    /// cgWindowID 缺失的窗口不参与记录（私有 API 不可用时整体退化为纯 z 序）
    func testRotateSkipsWindowsWithoutID() {
        let tracker = WindowMRUTracker()
        let windows = [item(nil), item(2), item(3)]
        tracker.rotate(windows, to: 1, pid: 42)
        XCTAssertEqual(tracker.ordered(windows, pid: 42).map(\.cgWindowID), [2, 3, nil])
    }

    // MARK: 快照与循环顺序的共存

    /// 焦点窗口 == 队首：顺序是「我们自己的激活」写的，按 z 序重排会打乱循环，必须跳过
    func testSnapshotKeepsOrderWhenFocusedIsHead() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(3), pid: 42)
        tracker.noteFocus(item(2), pid: 42)
        tracker.noteFocus(item(1), pid: 42)   // 队首 = 1，循环顺序 1,2,3
        // 组提升把刚用过的 1 留在原位，z 序呈现的是 1,3,2 这种假象
        tracker.snapshot(focusedWindowID: 1, visibleWindowIDs: [1, 3, 2], pid: 42, name: "t")
        XCTAssertEqual(tracker.ordered([item(1), item(2), item(3)], pid: 42).map(\.cgWindowID), [1, 2, 3])
    }

    /// 焦点窗口 ≠ 队首：用户手动切了窗，按 z 序对齐（兜底路径，未记录的窗口也补进来）
    func testSnapshotReseedsWhenFocusedDiffersFromHead() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(1), pid: 42)
        tracker.snapshot(focusedWindowID: 2, visibleWindowIDs: [2, 1, 3], pid: 42, name: "t")
        XCTAssertEqual(tracker.ordered([item(1), item(2), item(3)], pid: 42).map(\.cgWindowID), [2, 1, 3])
    }

    /// 队首判定按 pid 过滤：全局队首是别的应用时，本应用焦点命中自己的队首仍要跳过
    func testSnapshotHeadCheckIsPerApp() {
        let tracker = WindowMRUTracker()
        tracker.noteFocus(item(2), pid: 42)
        tracker.noteFocus(item(1), pid: 42)   // 本应用队首 = 1
        tracker.noteFocus(item(9), pid: 99)   // 另一个应用最后激活 → 全局队首是 99
        tracker.snapshot(focusedWindowID: 1, visibleWindowIDs: [1, 3, 2], pid: 42, name: "t")
        XCTAssertEqual(tracker.ordered([item(1), item(2), item(3)], pid: 42).map(\.cgWindowID), [1, 2, 3])
    }
}
