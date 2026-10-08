import XCTest
import AppKit
@testable import AppWindow

/// 切换器应用列表的准入规则：附件应用（本应用的设置窗口等）有普通可见窗口才入列，
/// 保证「打开设置窗口后能用 cmd+tab 切回」；系统代理（com.apple.*，如 WindowManager）
/// 即使有 layer-0 覆盖层窗口也不入列（用户反馈切不过去）
final class WindowListServiceTests: XCTestCase {

    func testRegularAppsAlwaysListed() {
        XCTAssertTrue(WindowListService.shouldList(
            policy: .regular, isTerminated: false, hasVisibleWindow: false,
            bundleIdentifier: "com.vendor.app"
        ), "常规应用无窗口也应列入（按 z-order 缺失沉底）")
        XCTAssertTrue(WindowListService.shouldList(
            policy: .regular, isTerminated: false, hasVisibleWindow: true,
            bundleIdentifier: "com.vendor.app"
        ))
        XCTAssertTrue(WindowListService.shouldList(
            policy: .regular, isTerminated: false, hasVisibleWindow: false,
            bundleIdentifier: "com.apple.Safari"
        ), "Apple 常规应用（Safari/Finder 等）照常列入")
    }

    func testAccessoryAppsListedOnlyWithVisibleWindow() {
        XCTAssertTrue(WindowListService.shouldList(
            policy: .accessory, isTerminated: false, hasVisibleWindow: true,
            bundleIdentifier: "com.vendor.menubar-tool"
        ), "设置窗口/工具窗口打开时，第三方附件应用应能出现在 cmd+tab 列表里")
        XCTAssertFalse(WindowListService.shouldList(
            policy: .accessory, isTerminated: false, hasVisibleWindow: false,
            bundleIdentifier: "com.vendor.menubar-tool"
        ), "无窗口的附件应用不应入列")
    }

    func testAppleSystemAgentsNeverListed() {
        XCTAssertFalse(WindowListService.shouldList(
            policy: .accessory, isTerminated: false, hasVisibleWindow: true,
            bundleIdentifier: "com.apple.WindowManager"
        ), "系统窗口管理代理的覆盖层窗口不应把它带进列表")
        XCTAssertFalse(WindowListService.shouldList(
            policy: .accessory, isTerminated: false, hasVisibleWindow: true,
            bundleIdentifier: "com.apple.wallpaper.agent"
        ), "其他 com.apple 附件代理同样不列入")
    }

    func testProhibitedAndTerminatedExcluded() {
        XCTAssertFalse(WindowListService.shouldList(
            policy: .prohibited, isTerminated: false, hasVisibleWindow: true,
            bundleIdentifier: "com.vendor.app"
        ), "系统代理类应用不列入")
        XCTAssertFalse(WindowListService.shouldList(
            policy: .regular, isTerminated: true, hasVisibleWindow: true,
            bundleIdentifier: "com.vendor.app"
        ), "已终止的应用不列入（图标已失效）")
        XCTAssertFalse(WindowListService.shouldList(
            policy: .accessory, isTerminated: true, hasVisibleWindow: true,
            bundleIdentifier: "com.vendor.app"
        ))
    }
}
