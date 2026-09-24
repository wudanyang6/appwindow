import AppKit
import ApplicationServices

/// 窗口级 MRU（最近使用在前）：app 失活时快照其窗口使用序，取用窗口列表时按该序排列。
/// 弥补 z-order 的盲区——其他 Space / 最小化的窗口不在 CG 可见列表里，历史使用顺序会丢失。
/// 与 app 级 MRU 同模式：冒泡更新、匹配不上的记录自然失效、无记录时退化为纯 z-order。
/// cmd+` 的每次激活额外做一次循环栈旋转（见 rotate）：目标窗口到队首、刚用过的沉底，
/// 使「列表顺序 = 循环顺序」，下一次按键前进到未用过的窗口而不是回到上一个。
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
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.axTimeout)
        snapshot(focusedWindowID: axApp.focusedWindow?.cgWindowID,
                 visibleWindowIDs: WindowListService.visibleWindows(pid: pid).map(\.id),
                 pid: pid, name: app.localizedName ?? "?")
    }

    /// 快照主体：AX 取值与排序逻辑分开，排序部分纯逻辑便于单测；name 只用于日志。
    /// 焦点窗口正是该应用 MRU 队首时跳过——这一轮顺序就是「我们自己的激活」写下的
    /// （cmd+` 的循环栈），此刻的 z 序是组提升造成的假象：刚用过的窗口仍留在第二位，
    /// 按它重排会把循环顺序打回「来回横跳」。其余情况（用户手动切窗、新窗口、无记录）
    /// 照旧按 z 序对齐，作为兜底。
    /// 代价：用户手动切走又切回队首窗口时判定不出来（应用内切窗没有任何通知），
    /// 顺序不更新——只影响「下一个窗口是谁」，不影响正确性
    func snapshot(focusedWindowID: CGWindowID?, visibleWindowIDs: [CGWindowID],
                  pid: pid_t, name: String) {
        let focused = focusedWindowID.map { Key(pid: pid, windowID: $0) }
        if let focused, focused == firstTrackedKey(pid: pid) {
            DiagLog.log("mru-snapshot", "\(name)(\(pid)) skip: focused == head，保住循环顺序")
            return
        }

        var keys: [Key] = []
        if let focused { keys.append(focused) }
        for id in visibleWindowIDs {
            let key = Key(pid: pid, windowID: id)
            guard !keys.contains(key) else { continue }
            keys.append(key)
        }
        DiagLog.log("mru-snapshot", "\(name)(\(pid)) "
            + "focused=\(focusedWindowID.map(String.init) ?? "nil") visible=\(visibleWindowIDs.count)")
        note(keys)
    }

    /// 提交窗口切换：按「循环栈」旋转——目标窗口排到最前，目标之前的窗口（刚用过的那些）
    /// 沉到最下方。这样下一次 cmd+` 前进到未使用的窗口，而不是回到上一个（原生 cmd+` 语义）。
    /// reference 是面板展示的顺序，index 是其中的目标位置；只由 cmd+` 的激活路径调用，
    /// cmd+tab 的窗口提交仍走 noteFocus 的冒泡语义
    func rotate(_ reference: [WindowItem], to index: Int, pid: pid_t) {
        guard reference.indices.contains(index) else { return }
        // cgWindowID 缺失的窗口无法参与记录（私有 API 不可用时整体退化为纯 z 序）
        let keys = reference.compactMap { window -> Key? in
            guard let id = window.cgWindowID else { return nil }
            return Key(pid: pid, windowID: id)
        }
        guard let target = reference[index].cgWindowID else {
            // 私有 API 不可用（cgWindowID 恒为 nil）时整体退化为纯 z 序，记一行便于排查
            DiagLog.log("mru-rotate", "pid=\(pid) skip: target 无 cgWindowID")
            return
        }
        guard let position = keys.firstIndex(of: Key(pid: pid, windowID: target)) else { return }

        let rotated = Array(keys[position...]) + Array(keys[..<position])
        DiagLog.log("mru-rotate", "\(pid) → "
            + (Array(reference[index...]) + Array(reference[..<index]))
                .map { "\"\($0.title)\"" }.joined(separator: " "))
        note(rotated)
    }

    /// 该应用在 MRU 里最靠前的一条记录；本会话还没记录过它的窗口时为 nil
    private func firstTrackedKey(pid: pid_t) -> Key? {
        order.first { $0.pid == pid }
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
