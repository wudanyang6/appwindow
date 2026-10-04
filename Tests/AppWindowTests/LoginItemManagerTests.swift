import XCTest
@testable import AppWindow

/// 开机自启动封装契约：注册/注销、状态重读、失败回滚
final class LoginItemManagerTests: XCTestCase {

    private final class FakeService: LoginItemServicing {
        var status: LoginItemState
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCount = 0
        private(set) var unregisterCount = 0

        init(status: LoginItemState) {
            self.status = status
        }

        func register() throws {
            registerCount += 1
            if let registerError { throw registerError }
            status = .enabled
        }

        func unregister() throws {
            unregisterCount += 1
            if let unregisterError { throw unregisterError }
            status = .notRegistered
        }
    }

    func testEnableRegistersAndReflectsStatus() throws {
        let service = FakeService(status: .notRegistered)
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(true)

        XCTAssertEqual(manager.state, .enabled)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    func testDisableUnregisters() throws {
        let service = FakeService(status: .enabled)
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(false)

        XCTAssertEqual(manager.state, .notRegistered)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    func testRegisterFailurePropagatesAndKeepsState() {
        let service = FakeService(status: .notRegistered)
        service.registerError = NSError(domain: "test.domain", code: 1)
        let manager = LoginItemManager(service: service)

        XCTAssertThrowsError(try manager.setEnabled(true))
        XCTAssertEqual(manager.state, .notRegistered)
    }

    func testRequiresApprovalIsReportedAsIs() {
        let service = FakeService(status: .requiresApproval)
        let manager = LoginItemManager(service: service)

        XCTAssertEqual(manager.state, .requiresApproval)
    }

    func testUnregisterFailurePropagates() {
        let service = FakeService(status: .enabled)
        service.unregisterError = NSError(domain: "test.domain", code: 2)
        let manager = LoginItemManager(service: service)

        XCTAssertThrowsError(try manager.setEnabled(false))
        XCTAssertEqual(manager.state, .enabled)
    }
}
