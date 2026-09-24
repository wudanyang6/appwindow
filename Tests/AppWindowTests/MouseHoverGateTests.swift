import XCTest
import AppKit
@testable import AppWindow

/// 鼠标移动判据：只有相对锚点位移超过 epsilon(0.5) 才算「真的动了」，
/// 锚点仅在判定移动时更新——用于过滤静止光标下 AppKit 补发的合成事件。
final class MouseHoverGateTests: XCTestCase {

    func testWithinEpsilonIsNotMovement() {
        let gate = MouseHoverGate(anchor: CGPoint(x: 100, y: 100))
        XCTAssertFalse(gate.hasMoved(to: CGPoint(x: 100.3, y: 100.3)))
        XCTAssertFalse(gate.hasMoved(to: CGPoint(x: 100, y: 100)))
    }

    func testBeyondEpsilonIsMovement() {
        let gate = MouseHoverGate(anchor: CGPoint(x: 100, y: 100))
        XCTAssertTrue(gate.hasMoved(to: CGPoint(x: 101, y: 100)))
        XCTAssertTrue(gate.hasMoved(to: CGPoint(x: 101, y: 102)))
    }

    func testAnchorUpdatesOnlyOnDetectedMovement() {
        let gate = MouseHoverGate(anchor: CGPoint(x: 100, y: 100))
        XCTAssertTrue(gate.hasMoved(to: CGPoint(x: 110, y: 100)))  // 动 → 锚点更新到 110
        XCTAssertFalse(gate.hasMoved(to: CGPoint(x: 110, y: 100))) // 相对新锚点没动
        XCTAssertTrue(gate.hasMoved(to: CGPoint(x: 120, y: 100)))
    }

    func testSubEpsilonStepsAccumulateAgainstFixedAnchor() {
        let gate = MouseHoverGate(anchor: CGPoint(x: 0, y: 0))
        XCTAssertFalse(gate.hasMoved(to: CGPoint(x: 0.3, y: 0))) // <0.5，锚点不动
        XCTAssertTrue(gate.hasMoved(to: CGPoint(x: 0.6, y: 0)))  // 相对锚点(0)累积到 0.6>0.5
    }
}
