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
    // 经缓存的图标：切换器每次重渲染都新建图标视图，直接用 NSRunningApplication.icon
    // 每次拿到的是未解码的多表示图像，重图标（iDev 有 32 个表示）首帧会空白闪烁。
    // 缓存同一个 NSImage 对象复用即可：它的表示只解码一次、后续绘制直接命中
    var icon: NSImage? { AppIconCache.icon(for: app) }
}

/// 应用图标缓存：按 pid 缓存同一个 NSImage 对象，避免每次渲染重新取用/解码。
/// 只在**一次切换会话内**有效（会话结束调用 clear 清空），因此应用换了图标下次打开即刷新；
/// 只在主线程访问（切换器构建与渲染都在主线程），无需加锁
enum AppIconCache {
    private static var cache: [pid_t: NSImage] = [:]

    static func icon(for app: NSRunningApplication) -> NSImage? {
        let pid = app.processIdentifier
        if let cached = cache[pid] { return cached }
        guard let image = app.icon else { return nil }
        cache[pid] = image
        return image
    }

    /// 切换会话结束时清空：下次打开面板重新取用各应用当前图标
    static func clear() {
        cache.removeAll()
    }
}

/// 枚举应用的窗口：CGWindowList 提供可靠的 z-order，AX 提供标题与可激活的窗口引用，
/// 两者通过 windowID（首选）或 bounds（兜底）关联。
enum WindowListService {

    private static let axTimeout: Float = 0.25

    /// 所有可切换应用，按 CGWindowList 全局 z-order 推导的最近使用顺序排列；
    /// 无可见窗口的应用（最小化/隐藏）沉底。
    static func switcherApps() -> [SwitcherApp] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // 刚退出的应用在 runningApplications 里会短暂残留（终止是异步的），此刻其 .icon 已为 nil，
        // 不过滤就会以空白图标出现在面板上；isTerminated 已翻真，据此剔除
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID && !$0.isTerminated
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

        let rawWindows = axApp.windows
        guard !rawWindows.isEmpty else { return [] }

        // 每个 AX 窗口一次批量取属性（title/document/subrole/minimized/position/size）+ 一次
        // 私有 cgWindowID：把此前逐属性 ~5-8 次跨进程往返压到每窗口约 2 次
        let infos = rawWindows.map(AXWindowInfo.init)

        // 剔除不是用户窗口的条目后再编号：否则标题回退编号会把幽灵行算进去（如「访达 3」「QQ音乐 2」）。
        // hasStandardWindow：应用是否存在正常的 AXStandardWindow，用于安全剔除 AXUnknown 幽灵窗口
        let auxiliary = auxiliaryWindowIDs(pid: app.processIdentifier)
        let hasStandardWindow = infos.contains { $0.subrole == standardWindowSubrole }
        let userInfos = infos.filter {
            isUserWindow($0, auxiliary: auxiliary, hasStandardWindow: hasStandardWindow)
        }

        let fallbackTitle = app.localizedName ?? "Window"
        let visible = visibleWindows(pid: app.processIdentifier)

        let byID = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1.id, $0) })
        // CGRect 的 Hashable 依赖 macOS 15+，这里用字符串做 bounds 匹配的 key
        var byBounds: [String: Int] = [:]
        for (index, window) in visible.enumerated() where byBounds[boundsKey(window.bounds)] == nil {
            byBounds[boundsKey(window.bounds)] = index
        }

        // 匹配不上的（如最小化窗口，不在 OnScreenOnly 列表里）沉底
        func rank(id: CGWindowID?, bounds: CGRect) -> Int {
            if let id, let rank = byID[id] { return rank }
            return byBounds[boundsKey(bounds)] ?? Int.max
        }

        // 标题回退编号按剔除后的次序（enumerated），排序在其后不影响编号
        let ranked = userInfos.enumerated().map { index, info -> (item: WindowItem, rank: Int) in
            let bounds = CGRect(origin: info.position ?? .zero, size: info.size ?? .zero)
            let r = rank(id: info.cgWindowID, bounds: bounds)
            return (WindowItem(axWindow: info.window,
                               title: info.title(fallback: fallbackTitle, index: index),
                               isMinimized: info.isMinimized,
                               cgWindowID: info.cgWindowID,
                               isOnScreen: r != Int.max), r)
        }
        // 不截断：选择面板的视口 + 滚动机制可承载任意行数
        return ranked.sorted { $0.rank < $1.rank }.map(\.item)
    }

    /// 单个 AX 窗口的属性快照：一次批量 IPC 取全，避免逐属性多次往返
    private struct AXWindowInfo {
        let window: AXUIElement
        let subrole: String?
        let isMinimized: Bool
        let cgWindowID: CGWindowID?
        let position: CGPoint?
        let size: CGSize?
        private let rawTitle: String?
        private let documentPath: String?

        init(_ window: AXUIElement) {
            self.window = window
            let values = window.attributeValues([
                kAXTitleAttribute as String, kAXDocumentAttribute as String,
                kAXSubroleAttribute as String, kAXMinimizedAttribute as String,
                kAXPositionAttribute as String, kAXSizeAttribute as String
            ])
            let title = values[0] as? String
            self.rawTitle = (title?.isEmpty == false) ? title : nil
            self.documentPath = values[1] as? String
            self.subrole = values[2] as? String
            self.isMinimized = (values[3] as? NSNumber)?.boolValue ?? false
            self.position = AXUIElement.cgPoint(from: values[4])
            self.size = AXUIElement.cgSize(from: values[5])
            self.cgWindowID = window.cgWindowID
        }

        /// 标题回退：AX 标题 → 文档名 → 应用名（首个）或「应用名 N」
        func title(fallback: String, index: Int) -> String {
            if let rawTitle { return rawTitle }
            if let documentPath {
                let name = (documentPath as NSString).lastPathComponent
                if !name.isEmpty { return name }
            }
            return index == 0 ? fallback : "\(fallback) \(index + 1)"
        }
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
        cgWindows([.optionOnScreenOnly, .excludeDesktopElements])
            .filter(\.isNormal)
            .map { ($0.id, $0.bounds, $0.pid) }
    }

    /// CGWindowList 的一条记录；layer/alpha 是判断「这是不是一个普通窗口」的依据
    private struct CGWindow {
        let id: CGWindowID
        let bounds: CGRect
        let pid: pid_t
        let layer: Int
        let alpha: Double

        /// 普通窗口：位于普通窗口层且不完全透明。
        /// 最小化与应用隐藏（Cmd+H）只改 onscreen 标志，不动 layer 与 alpha，因此不会被误判
        var isNormal: Bool { layer == 0 && alpha > 0 }
    }

    private static func cgWindows(_ option: CGWindowListOption) -> [CGWindow] {
        guard let list = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            // 字段缺失时按普通窗口处理：宁可多显示一行，也不误删真窗口
            return CGWindow(
                id: CGWindowID(id),
                bounds: bounds,
                pid: pid_t(pid),
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1
            )
        }
    }

    /// AX 的窗口列表混着不是用户窗口的条目，展示出来就是幽灵行：
    /// - Finder 的桌面（subrole=AXDesktop、没有 CG 窗口，标题回退成「访达 3」）
    /// - iTerm2 的独立 tab bar（CG 侧是 layer 24 / alpha 0 的辅助层窗口，AX 却当普通窗口返回）
    /// - QQ音乐 与真窗口完全重叠的 AXUnknown 覆盖窗口（CG 侧同样 layer 0 / alpha 1，无法靠 CG 区分）
    private static func isUserWindow(_ info: AXWindowInfo, auxiliary: Set<CGWindowID>,
                                     hasStandardWindow: Bool) -> Bool {
        if info.subrole == desktopSubrole { return false }
        // AXUnknown 是应用没有归类的辅助/覆盖窗口；仅当同一应用还存在正常的 AXStandardWindow
        // 时才剔除，避免把「窗口全是 AXUnknown」的应用整个抹掉（宁可多显示也不误删真窗口）
        if info.subrole == unknownSubrole && hasStandardWindow { return false }
        // 私有 API 不可用时 cgWindowID 恒为 nil，此时只能相信 AX 报的窗口列表
        guard let id = info.cgWindowID else { return true }
        return !auxiliary.contains(id)
    }

    // 公开 SDK 无桌面 subrole 常量，用系统实际返回的字符串；其余用 SDK 常量避免拼写漂移
    private static let desktopSubrole = "AXDesktop"
    private static let unknownSubrole = kAXUnknownSubrole as String
    private static let standardWindowSubrole = kAXStandardWindowSubrole as String

    /// 指定应用名下「非普通窗口」的 CG 窗口 ID 集合（辅助层或完全透明）
    private static func auxiliaryWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        return Set(
            cgWindows(options)
                .filter { $0.pid == pid && !$0.isNormal }
                .map(\.id)
        )
    }

    /// 指定 app 在当前 Space 的可见窗口，z-order 排列（最前在最前）；
    /// WindowMRUTracker 失活快照复用它推导窗口使用序
    static func visibleWindows(pid: pid_t) -> [(id: CGWindowID, bounds: CGRect)] {
        allVisibleWindows()
            .filter { $0.pid == pid }
            .map { ($0.id, $0.bounds) }
    }
}
