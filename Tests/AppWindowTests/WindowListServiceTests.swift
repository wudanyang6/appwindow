import XCTest
import AppKit
@testable import AppWindow

/// 切换器应用列表的准入规则：附件应用（本应用的设置窗口等）有普通可见窗口才入列，
/// 保证「打开设置窗口后能用 cmd+tab 切回」，又不产生切过去没窗口的幽灵条目
final class WindowListServiceTests: XCTestCase {

    func testRegularAppsAlwaysListed() {
        XCTAssertTrue(WindowListService.shouldList(
            policy: .regular, isTerminated: false, hasVisibleWindow: false
        ), "常规应用无窗口也应列入（按 z-order 缺失沉底）")
        XCTAssertTrue(WindowListService.shouldList(
            policy: .regular, isTerminated: false, hasVisibleWindow: true
        ))
    }

    func testAccessoryAppsListedOnlyWithVisibleWindow() {
        XCTAssertTrue(WindowListService.shouldList(
            policy: .accessory, isTerminated: false, hasVisibleWindow: true
        ), "设置窗口打开时，本应用应能出现在 cmd+tab 列表里")
        XCTAssertFalse(WindowListService.shouldList(
            policy: .accessory, isTerminated: false, hasVisibleWindow: false
        ), "无窗口的附件应用不应入列")
    }

    func testProhibitedAndTerminatedExcluded() {
        XCTAssertFalse(WindowListService.shouldList(
            policy: .prohibited, isTerminated: false, hasVisibleWindow: true
        ), "系统代理类应用不列入")
        XCTAssertFalse(WindowListService.shouldList(
            policy: .regular, isTerminated: true, hasVisibleWindow: true
        ), "已终止的应用不列入（图标已失效）")
        XCTAssertFalse(WindowListService.shouldList(
            policy: .accessory, isTerminated: true, hasVisibleWindow: true
        ))
    }
}
