import AppKit

/// 区分"用户真的移动了鼠标"与"AppKit 对静止光标补发的合成事件"。
/// 面板在静止光标下显示时，AppKit 会按光标当前位置补发 mouseEntered（甚至 mouseMoved），
/// 事件种类不可靠；改用物理判据——事件位置相对锚点真正变化才算移动，
/// 静止光标产生的所有合成事件位置都等于静止点，一律被滤除。
final class MouseHoverGate {

    /// 亚像素抖动与坐标换算误差不算移动
    private static let epsilon: CGFloat = 0.5

    private var anchor: NSPoint

    init() {
        anchor = NSEvent.mouseLocation
    }

    /// 注入初始锚点：供单测构造确定性场景（生产用无参 init 取实时光标位置）
    init(anchor: NSPoint) {
        self.anchor = anchor
    }

    /// 事件位置距锚点超过阈值才返回 true；
    /// 锚点仅在判定为移动时更新，极慢的连续移动靠累积位移触发
    func hasMoved(to screenLocation: NSPoint) -> Bool {
        guard abs(screenLocation.x - anchor.x) > Self.epsilon
                || abs(screenLocation.y - anchor.y) > Self.epsilon else { return false }
        anchor = screenLocation
        return true
    }

    /// 事件位置（window 坐标）换算成全局屏幕坐标后判定；多屏下各面板 window 坐标系不同，
    /// 必须统一到全局坐标才能与锚点比较
    func hasMoved(inWindow location: NSPoint, of window: NSWindow) -> Bool {
        let rect = window.convertToScreen(NSRect(origin: location, size: .zero))
        return hasMoved(to: rect.origin)
    }
}
