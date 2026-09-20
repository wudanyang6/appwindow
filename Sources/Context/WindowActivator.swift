import AppKit
import ApplicationServices

enum WindowActivator {

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
