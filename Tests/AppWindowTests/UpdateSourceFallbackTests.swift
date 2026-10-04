import XCTest
import Sparkle
@testable import AppWindow

/// 镜像回退的 URL 改写与换源策略契约：
/// 只有网络类/抓取类错误才换源，成功或业务类错误复位尝试记录
final class UpdateSourceFallbackTests: XCTestCase {

    private let appcastURL = URL(
        string: "https://raw.githubusercontent.com/wudanyang6/appwindow/main/appcast.xml"
    )!
    private let dmgURL = URL(
        string: "https://github.com/wudanyang6/appwindow/releases/download/v0.8.0/AppWindow-0.8.0.dmg"
    )!

    // MARK: - URL 改写

    func testGithubSourceKeepsGitHubURLsUnchanged() {
        XCTAssertEqual(UpdateSource.github.url(for: appcastURL), appcastURL)
        XCTAssertEqual(UpdateSource.github.url(for: dmgURL), dmgURL)
    }

    func testGhProxyPrefixesGitHubURLs() {
        XCTAssertEqual(
            UpdateSource.ghProxy.url(for: appcastURL).absoluteString,
            "https://gh-proxy.com/https://raw.githubusercontent.com/wudanyang6/appwindow/main/appcast.xml"
        )
        XCTAssertEqual(
            UpdateSource.ghProxy.url(for: dmgURL).absoluteString,
            "https://gh-proxy.com/https://github.com/wudanyang6/appwindow/releases/download/v0.8.0/AppWindow-0.8.0.dmg"
        )
    }

    func testGhFastPrefixesGitHubURLs() {
        XCTAssertEqual(
            UpdateSource.ghFast.url(for: appcastURL).absoluteString,
            "https://ghfast.top/https://raw.githubusercontent.com/wudanyang6/appwindow/main/appcast.xml"
        )
    }

    func testProxySourcesLeaveNonGitHubURLsUnchanged() {
        let url = URL(string: "https://example.com/AppWindow.dmg")!
        XCTAssertEqual(UpdateSource.ghProxy.url(for: url), url)
    }

    // MARK: - 逐源回退

    func testAdvanceWalksThroughSourcesThenExhausts() {
        var fallback = UpdateSourceFallback()
        XCTAssertEqual(fallback.currentSource, .github)

        XCTAssertTrue(fallback.advanceAfterError(URLError(.cannotConnectToHost)))
        XCTAssertEqual(fallback.currentSource, .ghProxy)

        XCTAssertTrue(fallback.advanceAfterError(URLError(.timedOut)))
        XCTAssertEqual(fallback.currentSource, .ghFast)

        // 全部试完：返回 false，本轮结束
        XCTAssertFalse(fallback.advanceAfterError(URLError(.networkConnectionLost)))
    }

    /// 环形推进：最后一个源失败后绕回最前面的源，不会永久卡在末尾
    func testAdvanceWrapsAroundAfterLastSource() {
        var fallback = UpdateSourceFallback(initialSource: .ghFast)

        XCTAssertTrue(fallback.advanceAfterError(URLError(.timedOut)))
        XCTAssertEqual(fallback.currentSource, .github)
    }

    /// 一轮耗尽复位后，下一轮仍能从当前源绕回重试
    func testExhaustedCycleCanRestart() {
        var fallback = UpdateSourceFallback()
        XCTAssertTrue(fallback.advanceAfterError(URLError(.timedOut)))
        XCTAssertTrue(fallback.advanceAfterError(URLError(.timedOut)))
        XCTAssertFalse(fallback.advanceAfterError(URLError(.timedOut)))

        XCTAssertTrue(fallback.advanceAfterError(URLError(.timedOut)))
        XCTAssertEqual(fallback.currentSource, .github)
    }

    func testSuccessResetsAttemptTracking() {
        var fallback = UpdateSourceFallback()
        XCTAssertTrue(fallback.advanceAfterError(URLError(.timedOut)))

        // 成功（error == nil）复位尝试记录，下一轮重新从当前源开始
        XCTAssertFalse(fallback.advanceAfterError(nil))
        XCTAssertEqual(fallback.currentSource, .ghProxy)
    }

    func testNonNetworkErrorDoesNotAdvance() {
        var fallback = UpdateSourceFallback()
        let error = NSError(domain: "test.domain", code: 1)

        XCTAssertFalse(fallback.advanceAfterError(error))
        XCTAssertEqual(fallback.currentSource, .github)
    }

    func testSparkleFetchErrorsTriggerAdvance() {
        var fallback = UpdateSourceFallback()
        let appcastError = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.appcastError.rawValue)
        )

        XCTAssertTrue(fallback.advanceAfterError(appcastError))
        XCTAssertEqual(fallback.currentSource, .ghProxy)
    }

    func testDownloadErrorTriggersAdvance() {
        var fallback = UpdateSourceFallback()
        let downloadError = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.downloadError.rawValue)
        )

        XCTAssertTrue(fallback.advanceAfterError(downloadError))
    }

    /// 「已是最新」以 noUpdateError 进入完成回调，不能误触发换源
    func testNoUpdateErrorDoesNotAdvance() {
        var fallback = UpdateSourceFallback()
        let noUpdateError = NSError(
            domain: SUSparkleErrorDomain,
            code: Int(SUError.noUpdateError.rawValue)
        )

        XCTAssertFalse(fallback.advanceAfterError(noUpdateError))
        XCTAssertEqual(fallback.currentSource, .github)
    }

    func testNestedUnderlyingURLErrorTriggersAdvance() {
        var fallback = UpdateSourceFallback()
        let wrapped = NSError(
            domain: "wrapped.domain",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost)]
        )

        XCTAssertTrue(fallback.advanceAfterError(wrapped))
    }

    func testCanAdvanceMirrorsAdvanceWithoutMutatingState() {
        let fallback = UpdateSourceFallback()

        XCTAssertTrue(fallback.canAdvanceAfterError(URLError(.timedOut)))
        XCTAssertEqual(fallback.currentSource, .github)

        XCTAssertFalse(fallback.canAdvanceAfterError(nil))
        XCTAssertFalse(fallback.canAdvanceAfterError(NSError(domain: "test.domain", code: 1)))
    }

    // MARK: - URL 输出

    func testAppcastURLStringUsesCurrentSource() {
        var fallback = UpdateSourceFallback()
        XCTAssertEqual(
            fallback.appcastURLString(from: appcastURL.absoluteString),
            appcastURL.absoluteString
        )

        _ = fallback.advanceAfterError(URLError(.timedOut))
        XCTAssertEqual(
            fallback.appcastURLString(from: appcastURL.absoluteString),
            "https://gh-proxy.com/" + appcastURL.absoluteString
        )
    }
}
