import AppKit
import ApplicationServices

enum WindowActivator {

    /// 恢复最小化 → AXRaise → 设为焦点窗口 → 激活应用。
    /// 设置 kAXFocusedWindow 后再 activate，系统通常会把目标窗口所在的 Space 带到前台。
    static func activate(_ item: WindowItem, app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        if item.isMinimized {
            pressMinimizeButton(of: item.axWindow)
        }

        item.axWindow.performAction(kAXRaiseAction)
        axApp.setAttribute(kAXFocusedWindowAttribute, item.axWindow)
        app.activate()
    }

    // AXRaise 拉不回最小化窗口，模拟点击它的最小化按钮来还原
    private static func pressMinimizeButton(of axWindow: AXUIElement) {
        guard let value = axWindow.copyAttribute(kAXMinimizeButtonAttribute) else { return }
        let button = value as! AXUIElement
        button.performAction(kAXPressAction)
    }
}
