import AppKit
import ApplicationServices

enum WindowActivator {

    /// 应用级激活（cmd+tab 默认提交路径）：activate 后聚焦 MRU 第一的窗口
    /// （面板列表第一行），activate 的系统决策不可控（macOS 26 实测会选偏），
    /// 显式聚焦保证「切到 app 即回到最近使用的窗口」。
    /// focus 对后台 app 无效，必须在 activate 之后执行；preferred 缺失
    /// （无窗口或最小化，原生 cmd+tab 不恢复最小化窗口）时退回纯 activate。
    /// 决策窗口与 preferred 不一致时存在「先决策后纠正」的短暂中间态（结构性，
    /// 见激活机制实测结论，不要试图用 AX 顺序调整消除）
    static func activateApp(_ app: NSRunningApplication, preferred: WindowItem?) {
        DiagLog.log("activate", "app-level app=\(app.localizedName ?? "?")(\(app.processIdentifier)) "
            + "preferred=\"\(preferred?.title ?? "nil")\"")

        guard let preferred else {
            app.activate()
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        app.activate()

        DispatchQueue.main.async {
            focus(preferred.axWindow, axApp: axApp)
            // 补拍：activate 异步生效等时序竞争的兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + focusRetryDelay) {
                focus(preferred.axWindow, axApp: axApp)
                verify(axApp: axApp)
            }
        }
    }

    /// 恢复最小化 → 聚焦窗口 → 视情况激活 app。
    /// 先走纯 AX（AXRaise + setFocused）：部分 app 的 setFocused 自带窗口级激活——
    /// 不触发 activate() 的组提升（把同 app 所有窗口拉到各自显示器/Space 最前，
    /// 多显示器下会打扰被遮挡的其他窗口）。下一 runloop 拍确认激活状态，未激活
    /// 才回退 app.activate()：它的窗口决策优先当前 Space 的可见窗口，会覆盖预设
    /// 焦点（实测 14 次跨 app 切换无一 app 响应纯 AX，全部回退；组提升与 macOS
    /// 原生 cmd+tab 一致，已接受）。
    static func activate(_ item: WindowItem, app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        DiagLog.log("activate", "app=\(app.localizedName ?? "?")(\(app.processIdentifier)) "
            + "window=\"\(item.title)\" id=\(item.cgWindowID.map(String.init) ?? "nil") "
            + "minimized=\(item.isMinimized) onScreen=\(item.isOnScreen)")
        DiagLog.log("z-before", WindowListService.diagnosticZOrder())

        if item.isMinimized {
            pressMinimizeButton(of: item.axWindow)
        }

        focus(item.axWindow, axApp: axApp)
        DiagLog.log("focus", "immediate, frontmost=\(frontPIDLabel())")

        DispatchQueue.main.async {
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

    private static func focus(_ axWindow: AXUIElement, axApp: AXUIElement) {
        axWindow.performAction(kAXRaiseAction)
        axApp.setAttribute(kAXFocusedWindowAttribute, axWindow)
    }

    private static func frontPIDLabel() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "nil" }
        return "\(front.localizedName ?? "?")(\(front.processIdentifier))"
    }

    // AXRaise 拉不回最小化窗口，模拟点击它的最小化按钮来还原
    private static func pressMinimizeButton(of axWindow: AXUIElement) {
        guard let value = axWindow.copyAttribute(kAXMinimizeButtonAttribute) else { return }
        let button = value as! AXUIElement
        button.performAction(kAXPressAction)
    }
}
