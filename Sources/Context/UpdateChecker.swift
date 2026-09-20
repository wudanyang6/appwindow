import AppKit

/// GitHub Release 更新检测：最新 tag 语义大于本地版本时在菜单栏提示。
/// 启动后延迟检查 + 24h 复查，结果只反映在菜单（idle 显示检查入口，
/// 出结果后显示版本状态），不发系统通知
final class UpdateChecker: NSObject {

    enum State {
        case idle
        case upToDate(current: String)
        case available(latest: String)
    }

    /// 检查完成（无论是否有更新）时回调，App 重建菜单
    var onStateChanged: (() -> Void)?

    private(set) var state: State = .idle
    private var releaseURL: URL?

    private let currentVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func start() {
        checkNow()
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    func checkNow() {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/wudanyang6/appwindow/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // 网络失败静默放弃：状态保持不变，用户可从菜单重新触发
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let url = (json["html_url"] as? String).flatMap(URL.init)
            DispatchQueue.main.async {
                self?.handle(tag: tag, url: url)
            }
        }.resume()
    }

    func openReleasePage() {
        if let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/wudanyang6/appwindow/releases/latest")!)
        }
    }

    private func handle(tag: String, url: URL?) {
        if Self.isNewer(tag, than: currentVersion) {
            releaseURL = url
            state = .available(latest: tag)
        } else {
            state = .upToDate(current: currentVersion)
        }
        onStateChanged?()
    }
}

extension UpdateChecker {

    /// "v0.1.10" 与 "0.1.2" 的语义比较：去 v 前缀、按点分段数值比较，段数不足补零
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func segments(_ version: String) -> [Int] {
            version.drop(while: { $0 == "v" }).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = segments(latest)
        let b = segments(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
