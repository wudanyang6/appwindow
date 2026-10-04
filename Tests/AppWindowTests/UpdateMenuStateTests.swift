import XCTest
@testable import AppWindow

/// 更新菜单状态机契约：全转换表 + 重试不闪 + 后台结果保留
final class UpdateMenuStateTests: XCTestCase {

    func testManualCheckFindsUpdate() {
        var machine = UpdateStateMachine()
        machine.cycleStarted()
        XCTAssertEqual(machine.state, .checking)
        machine.found(version: "0.9.0")
        XCTAssertEqual(machine.state, .available(version: "0.9.0"))
        // 用户关闭更新会话 → idle
        machine.sessionFinished()
        XCTAssertEqual(machine.state, .idle)
        // 会话结束后 cycle 收尾不覆盖
        machine.cycleFinished(retrying: false)
        XCTAssertEqual(machine.state, .idle)
    }

    func testManualCheckUpToDate() {
        var machine = UpdateStateMachine()
        machine.cycleStarted()
        machine.notFound(isOnLatestVersion: true, currentVersion: "0.8.0")
        XCTAssertEqual(machine.state, .upToDate(version: "0.8.0"))
        // 「已是最新」提示的会话结束不应清掉状态（该回调只对更新会话触发；
        // 若触发也允许回 idle，这里固化「保留」行为：cycle 收尾不覆盖非 checking 状态）
        machine.cycleFinished(retrying: false)
        XCTAssertEqual(machine.state, .upToDate(version: "0.8.0"))
    }

    func testNotFoundForSystemReasonDoesNotClaimUpToDate() {
        var machine = UpdateStateMachine()
        machine.cycleStarted()
        machine.notFound(isOnLatestVersion: false, currentVersion: "0.8.0")
        XCTAssertEqual(machine.state, .idle)
    }

    func testBackgroundCheckFindsUpdateKeepsAvailable() {
        var machine = UpdateStateMachine()
        // 后台检查不主动 cycleStarted，直接由回调驱动
        machine.found(version: "0.9.0")
        machine.cycleFinished(retrying: false)
        XCTAssertEqual(machine.state, .available(version: "0.9.0"))
    }

    func testRetryKeepsChecking() {
        var machine = UpdateStateMachine()
        machine.cycleStarted()
        machine.cycleFinished(retrying: true)
        XCTAssertEqual(machine.state, .checking)
        // 重试后仍失败并收尾 → idle
        machine.cycleFinished(retrying: false)
        XCTAssertEqual(machine.state, .idle)
    }

    func testCycleFinishedDoesNotOverwriteAvailable() {
        var machine = UpdateStateMachine()
        machine.cycleStarted()
        machine.found(version: "0.9.0")
        // 后台发现更新但用户没关会话前 cycle 收尾（如自动下载完成）
        machine.cycleFinished(retrying: false)
        XCTAssertEqual(machine.state, .available(version: "0.9.0"))
    }

    func testReset() {
        var machine = UpdateStateMachine()
        machine.cycleStarted()
        machine.reset()
        XCTAssertEqual(machine.state, .idle)
    }
}
