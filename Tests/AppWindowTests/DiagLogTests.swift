import XCTest
@testable import AppWindow

/// 诊断日志的惰性求值契约：关闭时（发布默认）不得求值消息实参，
/// 以免 diagnosticZOrder()（CGWindowList）等重开销在发布版白白执行。
final class DiagLogTests: XCTestCase {

    func testDisabledLogSkipsMessageEvaluation() {
        let original = DiagLog.isEnabled
        defer { DiagLog.isEnabled = original }

        DiagLog.isEnabled = false
        var evaluated = 0
        func message() -> String {
            evaluated += 1
            return "expensive"
        }
        DiagLog.log("test", message())   // @autoclosure：关闭时不应触发 message()
        XCTAssertEqual(evaluated, 0)
    }
}
