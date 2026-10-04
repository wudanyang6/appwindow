import XCTest
import Sparkle
@testable import AppWindow

/// 错误弹窗抑制契约：换源重试期间不弹窗（只 acknowledgement），
/// 重试耗尽后错误正常交给呈现方
@MainActor
final class UpdateFallbackUserDriverTests: XCTestCase {

    func testSuppressedErrorAcknowledgesWithoutPresenting() {
        var presentedErrorCode: Int?
        var acknowledgementCount = 0
        let error = URLError(.cannotConnectToHost)

        let driver = UpdateFallbackUserDriver(
            hostBundle: .main,
            delegate: nil,
            presentUpdaterError: { error, acknowledgement in
                presentedErrorCode = (error as? URLError)?.code.rawValue
                acknowledgement()
            }
        )
        driver.shouldSuppressUpdaterError = { _ in true }

        driver.showUpdaterError(error) {
            acknowledgementCount += 1
        }

        XCTAssertNil(presentedErrorCode)
        XCTAssertEqual(acknowledgementCount, 1)
    }

    func testUnsuppressedErrorReachesPresenter() {
        var presentedErrorCode: Int?
        var acknowledgementCount = 0
        let error = URLError(.timedOut)

        let driver = UpdateFallbackUserDriver(
            hostBundle: .main,
            delegate: nil,
            presentUpdaterError: { error, acknowledgement in
                presentedErrorCode = (error as? URLError)?.code.rawValue
                acknowledgement()
            }
        )
        driver.shouldSuppressUpdaterError = { _ in false }

        driver.showUpdaterError(error) {
            acknowledgementCount += 1
        }

        XCTAssertEqual(presentedErrorCode, error.code.rawValue)
        XCTAssertEqual(acknowledgementCount, 1)
    }
}
