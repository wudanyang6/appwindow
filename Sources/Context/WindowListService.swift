import AppKit
import ApplicationServices

struct WindowItem {
    let axWindow: AXUIElement
    let title: String
    let isMinimized: Bool
    // 窗口级 MRU 的匹配 key；私有 API 不可用时为 nil，MRU 自动退化为纯 z-order
    let cgWindowID: CGWindowID?
    // 在当前 Space 的 CG 可见列表中匹配成功（未最小化且不在其他 Space）
    let isOnScreen: Bool
}

/// cmd+tab 切换器中的一个应用条目，windows 惰性加载（首次高亮时才枚举）
struct SwitcherApp {
    let app: NSRunningApplication
    var windows: [WindowItem] = []
    // 单窗口应用的枚举结果为空数组，需要独立标志区分「未枚举」与「枚举过但无窗口」
    var windowsLoaded = false

    var name: String { app.localizedName ?? "App" }
    var icon: NSImage? { app.icon }
}

/// 枚举应用的窗口：CGWindowList 提供可靠的 z-order，AX 提供标题与可激活的窗口引用，
/// 两者通过 windowID（首选）或 bounds（兜底）关联。
enum WindowListService {

    private static let axTimeout: Float = 0.25

    /// 所有可切换应用，按 CGWindowList 全局 z-order 推导的最近使用顺序排列；
    /// 无可见窗口的应用（最小化/隐藏）沉底。
    static func switcherApps() -> [SwitcherApp] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }
        let byPID = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })

        var order: [pid_t] = []
        var seen = Set<pid_t>()
        for window in allVisibleWindows() where byPID[window.pid] != nil && !seen.contains(window.pid) {
            seen.insert(window.pid)
            order.append(window.pid)
        }

        let rest = running.filter { !seen.contains($0.processIdentifier) }
        let ordered = (order + rest.map(\.processIdentifier)).compactMap { byPID[$0] }
        return ordered.map { SwitcherApp(app: $0) }
    }

    static func windows(of app: NSRunningApplication) -> [WindowItem] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // 目标应用无响应时限制单次 AX 调用的阻塞时间，避免事件流卡死
        AXUIElementSetMessagingTimeout(axApp, axTimeout)

        let axWindows = axApp.windows
        guard !axWindows.isEmpty else { return [] }

        let fallbackTitle = app.localizedName ?? "Window"
        let visible = visibleWindows(pid: app.processIdentifier)

        var entries: [Entry] = axWindows.enumerated().map { index, ax -> Entry in
            Entry(
                axWindow: ax,
                title: title(of: ax, fallback: fallbackTitle, index: index),
                isMinimized: ax.isMinimized,
                cgWindowID: ax.cgWindowID,
                bounds: CGRect(origin: ax.position ?? .zero, size: ax.size ?? .zero)
            )
        }

        let byID = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1.id, $0) })
        // CGRect 的 Hashable 依赖 macOS 15+，这里用字符串做 bounds 匹配的 key
        var byBounds: [String: Int] = [:]
        for (index, window) in visible.enumerated() where byBounds[boundsKey(window.bounds)] == nil {
            byBounds[boundsKey(window.bounds)] = index
        }

        func rank(_ entry: Entry) -> Int {
            if let id = entry.cgWindowID, let rank = byID[id] { return rank }
            // 匹配不上的（如最小化窗口，不在 OnScreenOnly 列表里）沉底
            return byBounds[boundsKey(entry.bounds)] ?? Int.max
        }

        entries.sort { rank($0) < rank($1) }
        // 不截断：选择面板的视口 + 滚动机制可承载任意行数
        return entries.map { entry in
            WindowItem(
                axWindow: entry.axWindow,
                title: entry.title,
                isMinimized: entry.isMinimized,
                cgWindowID: entry.cgWindowID,
                isOnScreen: rank(entry) != Int.max
            )
        }
    }

    private struct Entry {
        let axWindow: AXUIElement
        let title: String
        let isMinimized: Bool
        let cgWindowID: CGWindowID?
        let bounds: CGRect
    }

    private static func boundsKey(_ rect: CGRect) -> String {
        "\(rect.origin.x),\(rect.origin.y),\(rect.size.width),\(rect.size.height)"
    }

    /// 诊断日志用：全局可见窗口的 z 序快照（app 名 + windowID；读窗口标题需要
    /// 屏幕录制权限，本工具没有，故只记 ID——与 activate 日志里的窗口 ID 对得上）
    static func diagnosticZOrder(limit: Int = 12) -> String {
        let byPID = Dictionary(uniqueKeysWithValues:
            NSWorkspace.shared.runningApplications
                .map { ($0.processIdentifier, $0.localizedName ?? "?") })
        let names = allVisibleWindows().prefix(limit)
            .map { "\(byPID[$0.pid] ?? "?")/\($0.id)" }
        return names.joined(separator: " ")
    }

    /// 全部应用的可见窗口，z-order 排列（最前在最前）；诊断日志的 z 序快照复用
    static func allVisibleWindows() -> [(id: CGWindowID, bounds: CGRect, pid: pid_t)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return (CGWindowID(id), bounds, pid_t(pid))
        }
    }

    /// 指定 app 在当前 Space 的可见窗口，z-order 排列（最前在最前）；
    /// WindowMRUTracker 失活快照复用它推导窗口使用序
    static func visibleWindows(pid: pid_t) -> [(id: CGWindowID, bounds: CGRect)] {
        allVisibleWindows()
            .filter { $0.pid == pid }
            .map { ($0.id, $0.bounds) }
    }

    private static func title(of axWindow: AXUIElement, fallback: String, index: Int) -> String {
        if let title = axWindow.title { return title }

        if let document = axWindow.documentPath {
            let name = (document as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }

        return index == 0 ? fallback : "\(fallback) \(index + 1)"
    }
}
