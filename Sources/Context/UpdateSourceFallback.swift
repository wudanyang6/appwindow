import Foundation
import Sparkle

/// 更新源：直连 GitHub 或经镜像前缀转发。
/// 大陆网络直连 raw.githubusercontent.com / github.com 常被阻断，
/// appcast 与 DMG 都按 github → gh-proxy → ghfast 逐源回退
enum UpdateSource: Hashable {
    case github
    case ghProxy
    case ghFast

    /// 镜像前缀；nil 表示直连
    private var proxyPrefix: String? {
        switch self {
        case .github: nil
        case .ghProxy: "https://gh-proxy.com/"
        case .ghFast: "https://ghfast.top/"
        }
    }

    /// 仅改写 GitHub 域名，其余 URL 原样返回
    func url(for url: URL) -> URL {
        guard
            let proxyPrefix,
            Self.isGitHubURL(url),
            let proxiedURL = URL(string: proxyPrefix + url.absoluteString)
        else {
            return url
        }

        return proxiedURL
    }

    private static func isGitHubURL(_ url: URL) -> Bool {
        switch url.host?.lowercased() {
        case "github.com", "raw.githubusercontent.com": true
        default: false
        }
    }
}

/// 逐源回退状态机：当前源失败后环形推进到下一个未尝试的源，全部试完自动复位。
/// 成功时停在当前可用源（下轮优先复用，避免每次都先撞已失效的源）；
/// 该源之后失败会绕回最前面的源继续尝试，不会永久卡在最后一个源上
struct UpdateSourceFallback {
    static let defaultSources: [UpdateSource] = [.github, .ghProxy, .ghFast]

    private let sources: [UpdateSource]
    private var attemptedSources: Set<UpdateSource> = []
    private(set) var currentSource: UpdateSource

    init(
        sources: [UpdateSource] = Self.defaultSources,
        initialSource: UpdateSource? = nil
    ) {
        let resolvedSources = sources.isEmpty ? Self.defaultSources : sources
        self.sources = resolvedSources
        self.currentSource = initialSource ?? resolvedSources[0]
    }

    func appcastURLString(from directURLString: String) -> String? {
        guard let directURL = URL(string: directURLString) else { return nil }
        return currentSource.url(for: directURL).absoluteString
    }

    func downloadURL(for appcastURL: URL) -> URL {
        currentSource.url(for: appcastURL)
    }

    /// 只读探测：当前错误是否还能推进到下一个未尝试的源（供错误弹窗抑制判断）
    func canAdvanceAfterError(_ error: Error?) -> Bool {
        guard UpdateSourceRetryPolicy.shouldTryNextSource(after: error) else {
            return false
        }

        guard let currentIndex = sources.firstIndex(of: currentSource) else {
            return false
        }

        return (1...sources.count).contains { offset in
            !attemptedSources.contains(sources[(currentIndex + offset) % sources.count])
        }
    }

    /// 推进到下一个源；返回 true 表示应换源重试，false 表示本轮结束（尝试记录复位）
    mutating func advanceAfterError(_ error: Error?) -> Bool {
        guard UpdateSourceRetryPolicy.shouldTryNextSource(after: error) else {
            attemptedSources.removeAll()
            return false
        }

        attemptedSources.insert(currentSource)

        guard let currentIndex = sources.firstIndex(of: currentSource) else {
            attemptedSources.removeAll()
            return false
        }

        for offset in 1...sources.count {
            let candidate = sources[(currentIndex + offset) % sources.count]
            if !attemptedSources.contains(candidate) {
                currentSource = candidate
                return true
            }
        }

        attemptedSources.removeAll()
        return false
    }
}

/// 换源条件：只认网络类与 Sparkle 抓取/下载类错误；签名、解析失败等不换源
private enum UpdateSourceRetryPolicy {
    static func shouldTryNextSource(after error: Error?) -> Bool {
        guard let error else { return false }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }

        if nsError.domain == SUSparkleErrorDomain {
            switch nsError.code {
            case Int(SUError.appcastError.rawValue),
                 Int(SUError.downloadError.rawValue):
                return true
            default:
                break
            }
        }

        // Sparkle 把 URLSession 错误包在上层错误里，需要递归下钻判断
        guard let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }

        return shouldTryNextSource(after: underlyingError)
    }
}
