import AppKit
import ApplicationServices

extension AXUIElement {

    func copyAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func setAttribute(_ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    func performAction(_ name: String) {
        AXUIElementPerformAction(self, name as CFString)
    }

    var windows: [AXUIElement] {
        copyAttribute(kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// app 当前焦点窗口；属性查询失败返回 nil，成功时值必为 AXUIElement（强制桥接）
    var focusedWindow: AXUIElement? {
        guard let value = copyAttribute(kAXFocusedWindowAttribute) else { return nil }
        return (value as! AXUIElement)
    }

    var title: String? {
        guard let title = copyAttribute(kAXTitleAttribute) as? String, !title.isEmpty else { return nil }
        return title
    }

    var documentPath: String? {
        copyAttribute(kAXDocumentAttribute) as? String
    }

    var isMinimized: Bool {
        (copyAttribute(kAXMinimizedAttribute) as? NSNumber)?.boolValue ?? false
    }

    /// AX 条目的 subrole（AXStandardWindow、AXApplicationDockItem、AXDesktop 等）；
    /// 属性缺失时为 nil。它并不稳定——实测同一个窗口在应用隐藏后从 AXStandardWindow
    /// 变成 AXDialog——因此只用于识别明确特例，不要拿它做「必须等于某值」的白名单判断
    var subrole: String? {
        copyAttribute(kAXSubroleAttribute) as? String
    }

    var position: CGPoint? {
        guard let value = copyAttribute(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    var size: CGSize? {
        guard let value = copyAttribute(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    var cgWindowID: CGWindowID? {
        AXPrivateAPI.cgWindowID(of: self)
    }
}

/// 隔离私有 API：_AXUIElementGetWindow 把 AXWindow 映射到 CGWindowID。
/// dlsym 动态解析，符号缺失时上层自动退化为 bounds 匹配，不影响编译。
private enum AXPrivateAPI {

    private static let getWindowID: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
        // dlopen(nil) 查不到该符号，必须显式打开 ApplicationServices
        let path = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    }()

    static func cgWindowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindowID else { return nil }
        var id: CGWindowID = 0
        guard getWindowID(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}
