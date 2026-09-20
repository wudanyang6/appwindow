import AppKit
import ApplicationServices

/// 窗口级 MRU（最近使用在前）：app 失活时快照其窗口使用序，取用窗口列表时按该序排列。
/// 弥补 z-order 的盲区——其他 Space / 最小化的窗口不在 CG 可见列表里，历史使用顺序会丢失。
/// 与 app 级 MRU 同模式：冒泡更新、匹配不上的记录自然失效、无记录时退化为纯 z-order。
final class WindowMRUTracker {

    // 记录 key：pid + windowID。窗口关闭后 key 匹配不上任何列表，无需显式清理
    private struct Key: Hashable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    // 失活快照一次插入 N 条，上限防止长会话无限增长
    private static let capacity = 128
    // 快照是 best-effort：AX 失败即退化为纯 z 序排序，不值得为挂起的应用阻塞主线程太久
    private static let axTimeout: Float = 0.1

    private var order: [Key] = []

    /// app 失活或即将取用其窗口列表时快照：AX focused + 可见窗口 z 序，冒泡到 MRU 头。
    /// 失活时刻的 z 序正好是「本次使用的最终状态」；focused 可能不可见（在其他 Space），
    /// 因此必须 AX 查询而不能只用 z 序头。AX 失败时退化为纯 z 序快照。
    func snapshot(_ app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Self.axTimeout)

        var keys: [Key] = []
        if let id = axApp.focusedWindow?.cgWindowID {
            keys.append(Key(pid: app.processIdentifier, windowID: id))
        }
        for window in WindowListService.visibleWindows(pid: app.processIdentifier) {
            let key = Key(pid: app.processIdentifier, windowID: window.id)
            guard !keys.contains(key) else { continue }
            keys.append(key)
        }
        DiagLog.log("mru-snapshot", "\(app.localizedName ?? "?")(\(app.processIdentifier)) "
            + "focused=\(!keys.isEmpty) visible=\(keys.count - 1)")
        note(keys)
    }

    /// 提交切换后立即记录目标窗口：最小化/跨 Space 窗口此刻尚不可见，
    /// 要等它再次失活才会被快照到，中间的取用会错过它
    func noteFocus(_ item: WindowItem, pid: pid_t) {
        guard let id = item.cgWindowID else { return }
        DiagLog.log("mru-focus", "pid=\(pid) id=\(id) title=\"\(item.title)\"")
        note([Key(pid: pid, windowID: id)])
    }

    /// 三段稳定排序：MRU 命中的按使用序在最前，未命中但可见的按 z 序居中，其余沉底。
    /// MRU 优先（而非 z 序优先）：z 序看不到跨 Space 窗口的新旧，这正是要修的问题。
    func ordered(_ windows: [WindowItem], pid: pid_t) -> [WindowItem] {
        guard !order.isEmpty else { return windows }

        // [Key: MRU 位置]，位置越小越最近；uniquing 防御未来调用者引入重复 key 崩溃
        let hit = Dictionary(order.enumerated().map { ($1, $0) },
                             uniquingKeysWith: { first, _ in first })

        var mruHit: [(rank: Int, item: WindowItem)] = []
        var onScreen: [WindowItem] = []
        var rest: [WindowItem] = []
        for window in windows {
            if let id = window.cgWindowID, let rank = hit[Key(pid: pid, windowID: id)] {
                mruHit.append((rank, window))
            } else if window.isOnScreen {
                onScreen.append(window)
            } else {
                rest.append(window)
            }
        }
        mruHit.sort { $0.rank < $1.rank }
        return mruHit.map(\.item) + onScreen + rest
    }

    /// keys 整组冒泡到最前，组内保持传入顺序（即使用序）
    private func note(_ keys: [Key]) {
        guard !keys.isEmpty else { return }
        let inserting = Set(keys)
        order.removeAll { inserting.contains($0) }
        order.insert(contentsOf: keys, at: 0)
        if order.count > Self.capacity {
            order.removeLast(order.count - Self.capacity)
        }
    }
}
