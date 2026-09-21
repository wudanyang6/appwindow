import AppKit

/// 用户偏好：菜单栏开关控制，UserDefaults 持久化
enum Settings {

    /// cmd+tab 面板延迟显示：快速点按（<100ms）不显示面板直接切换，
    /// 按住超过 100ms 面板才出现，对齐系统 cmd+tab 的按住显示行为。
    /// 延迟期间状态机照常（tab 移动高亮、Esc 取消），面板出现时读最新状态
    static var delayedPanel: Bool {
        get { UserDefaults.standard.bool(forKey: "delayedPanelEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "delayedPanelEnabled") }
    }
}
