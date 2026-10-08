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

    /// 面板背景材质的整体不透明度（0…1，默认 1 = 最不透明）。
    /// 调低 = 更透：背后内容透上来的比例更高，模糊观感随之变淡
    static var panelAlpha: Double {
        get {
            if let stored = UserDefaults.standard.object(forKey: "panelAlpha") as? NSNumber {
                return min(max(stored.doubleValue, 0), 1)
            }
            return 1
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: "panelAlpha")
            Theme.invalidateBackgrounds()
        }
    }

    /// 叠在毛玻璃（含加强模糊）之上的黑色 tint 着色量（0…1，默认 12%）：
    /// 降低亮度，让后面窗口透上来的清晰内容更少（越大越暗越「糊」）
    static var panelTintAlpha: Double {
        get {
            if let stored = UserDefaults.standard.object(forKey: "panelTintAlpha") as? NSNumber {
                return min(max(stored.doubleValue, 0), 1)
            }
            return 0.12
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: "panelTintAlpha")
            Theme.invalidateBackgrounds()
        }
    }

    /// 参与测试版：接收带 sparkle:channel=beta 的预发布版本（可能不稳定）；
    /// 关闭时只看默认通道（稳定版），已发布的稳定版更新不受影响
    static var betaChannel: Bool {
        get { UserDefaults.standard.bool(forKey: "betaChannelEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "betaChannelEnabled") }
    }
}
