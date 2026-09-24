import AppKit
import ApplicationServices

enum WindowActivator {

    /// 激活代次：cmd+` 改成「每按一次立即切换」后，一次会话内会有连续多次激活，
    /// 每次激活都排了延迟补拍。补拍执行前校验代次，已有更新的激活就放弃——
    /// 否则前一个窗口的补拍会在新激活之后把它又抬上来，出现「按了两次却停在旧窗口」。
    /// 两处激活共用同一计数器：最新一次激活为准。全主线程调用，无需加锁
    private static var generation = 0

    private static func beginActivation() -> Int {
        generation += 1
        return generation
    }

    private static func isCurrent(_ token: Int) -> Bool { token == generation }

    /// 应用级激活（cmd+tab 默认提交路径）：activate 后聚焦 MRU 第一的窗口
    /// （面板列表第一行），activate 的系统决策不可控（macOS 26 实测会选偏），
    /// 显式聚焦保证「切到 app 即回到最近使用的窗口」。
    /// focus 对后台 app 无效，必须在 activate 之后执行；preferred 缺失
    /// （无窗口或最小化，原生 cmd+tab 不恢复最小化窗口）时退回纯 activate。
    /// 决策窗口与 preferred 不一致时存在「先决策后纠正」的短暂中间态（结构性，
    /// 见激活机制实测结论，不要试图用 AX 顺序调整消除）
    static func activateApp(_ app: NSRunningApplication, preferred: WindowItem?) {
        // 先递增代次再判断分支：preferred 缺失时虽然用不到 token，但这次递增本身要生效——
        // 它负责压掉更早那次激活挂起的补拍
        let token = beginActivation()
        DiagLog.log("activate", "app-level app=\(app.localizedName ?? "?")(\(app.processIdentifier)) "
            + "preferred=\"\(preferred?.title ?? "nil")\"")

        guard let preferred else {
            app.activate()
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)
        app.activate()

        DispatchQueue.main.async {
            guard isCurrent(token) else { return }
            focus(preferred.axWindow, axApp: axApp)
            // 补拍：activate 异步生效等时序竞争的兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + focusRetryDelay) {
                guard isCurrent(token) else { return }
                focus(preferred.axWindow, axApp: axApp)
                verify(axApp: axApp)
            }
        }
    }

    /// 恢复最小化 → 聚焦窗口 → 视情况激活 app。
    /// **聚焦等 AX 调用排在主队列块里**：事件 tap 回调必须尽快返回——cmd+` 改成「每按一次
    /// 立即切换」后，激活从「一次会话一次」变成「一次按键一次」，在回调里同步做聚焦 AX 会让
    /// 连按时每次按键阻塞数十毫秒（实测 p50 75ms / max 149ms），目标应用卡住时更久，
    /// 还可能触发 tapDisabledByTimeout 丢按键。实测改造后回调段从 p50 82ms 降到 ≤1ms。
    /// 例外：最小化恢复（点最小化按钮）留在回调里——它只在目标窗口最小化时才发生，
    /// 且按钮与随后的聚焦之间刻意留一拍，给还原动画起步的时间。这条路径实测难以复现
    /// （非 bundle 脚本应用的窗口无法最小化，外部 AX 写属性会被忽略），改动请谨慎。
    /// 块内顺序与原同步路径一致：聚焦 → 探活 → 必要时 activate → 再聚焦 → +0.1s 补拍。
    /// 先走纯 AX（AXRaise + setFocused）：部分 app 的 setFocused 自带窗口级激活——
    /// 不触发 activate() 的组提升（把同 app 所有窗口拉到各自显示器/Space 最前，
    /// 多显示器下会打扰被遮挡的其他窗口）。下一 runloop 拍确认激活状态，未激活
    /// 才回退 app.activate()：它的窗口决策优先当前 Space 的可见窗口，会覆盖预设
    /// 焦点（实测 14 次跨 app 切换无一 app 响应纯 AX，全部回退；组提升与 macOS
    /// 原生 cmd+tab 一致，已接受）。
    static func activate(_ item: WindowItem, app: NSRunningApplication) {
        let token = beginActivation()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)

        DiagLog.log("activate", "app=\(app.localizedName ?? "?")(\(app.processIdentifier)) "
            + "window=\"\(item.title)\" id=\(item.cgWindowID.map(String.init) ?? "nil") "
            + "minimized=\(item.isMinimized) onScreen=\(item.isOnScreen)")

        if item.isMinimized {
            pressMinimizeButton(of: item.axWindow)
        }

        DispatchQueue.main.async {
            guard isCurrent(token) else { return }
            DiagLog.log("z-before", WindowListService.diagnosticZOrder())

            focus(item.axWindow, axApp: axApp)
            DiagLog.log("focus", "immediate, frontmost=\(frontPIDLabel())")

            let alreadyActive = NSWorkspace.shared.frontmostApplication?.processIdentifier
                == app.processIdentifier
            DiagLog.log("probe", "alreadyActive=\(alreadyActive) frontmost=\(frontPIDLabel())")
            if !alreadyActive {
                app.activate()
            }
            // 无论哪条激活路径，重新聚焦以纠正激活过程的窗口决策
            focus(item.axWindow, axApp: axApp)
            // 补拍：最小化恢复动画、activate 异步生效等时序竞争的兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + focusRetryDelay) {
                guard isCurrent(token) else { return }
                focus(item.axWindow, axApp: axApp)
                verify(axApp: axApp)
            }
        }
    }

    private static func verify(axApp: AXUIElement) {
        DiagLog.log("z-after", WindowListService.diagnosticZOrder())
        let focused = axApp.focusedWindow?.title ?? "?"
        DiagLog.log("verify", "frontmost=\(frontPIDLabel()) focused=\"\(focused)\"")
    }

    private static let focusRetryDelay: TimeInterval = 0.1
    // 单次 AX 调用的阻塞上限：目标应用无响应时不让调用方一直等
    private static let axTimeout: Float = 0.25

    private static func focus(_ axWindow: AXUIElement, axApp: AXUIElement) {
        axWindow.performAction(kAXRaiseAction)
        axApp.setAttribute(kAXFocusedWindowAttribute, axWindow)
    }

    private static func frontPIDLabel() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "nil" }
        return "\(front.localizedName ?? "?")(\(front.processIdentifier))"
    }

    // AXRaise 拉不回最小化窗口，模拟点击它的最小化按钮来还原。
    // 超时必须逐个元素设：AXUIElementSetMessagingTimeout 只对「被设置的那个元素」生效，
    // 应用元素上的 axTimeout 不会传导到窗口 / 按钮元素，挂起的应用会让这里无上限阻塞
    private static func pressMinimizeButton(of axWindow: AXUIElement) {
        AXUIElementSetMessagingTimeout(axWindow, axTimeout)
        guard let value = axWindow.copyAttribute(kAXMinimizeButtonAttribute) else { return }
        let button = value as! AXUIElement
        AXUIElementSetMessagingTimeout(button, axTimeout)
        button.performAction(kAXPressAction)
    }
}
