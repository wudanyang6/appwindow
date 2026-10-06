import AppKit

/// 面板背景材质：Regular / Clear 两种液态玻璃，或关闭玻璃退回毛玻璃
enum GlassMode: String, CaseIterable {
    case regular
    case clear
    case off
}

/// 用户偏好：菜单栏开关控制，UserDefaults 持久化
enum Settings {

    /// cmd+tab 面板延迟显示：快速点按（<100ms）不显示面板直接切换，
    /// 按住超过 100ms 面板才出现，对齐系统 cmd+tab 的按住显示行为。
    /// 延迟期间状态机照常（tab 移动高亮、Esc 取消），面板出现时读最新状态
    static var delayedPanel: Bool {
        get { UserDefaults.standard.bool(forKey: "delayedPanelEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "delayedPanelEnabled") }
    }

    /// 面板背景材质（原「不使用玻璃效果」开关升级为三选一）。
    /// Liquid Glass 的聚焦样式由系统按窗口 key 状态渲染、无法干预，观感异常时切 Clear 或关闭
    static var glassMode: GlassMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: "glassMode"),
               let mode = GlassMode(rawValue: raw) {
                return mode
            }
            // 兼容旧键：glassDisabled = true 视为关闭玻璃
            return UserDefaults.standard.bool(forKey: "glassDisabled") ? .off : .regular
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "glassMode") }
    }

    /// 玻璃下毛玻璃垫层的强度（0 = 关闭、不装配垫层；1 = 完全生效，默认）。
    /// 强度即垫层的不透明度：半透明模糊与清晰底层混合，观感上就是「模糊度」可调。
    /// 原为布尔开关，升级为连续值：旧键 true → 1、false → 0；两者都未设置过 → 默认 1
    static var glassUnderBlurStrength: Double {
        get {
            if let stored = UserDefaults.standard.object(forKey: "glassUnderBlurStrength") as? NSNumber {
                return min(max(stored.doubleValue, 0), 1)
            }
            // 兼容旧键：glassUnderBlurEnabled = false 视为 0%，其余（含未设置）视为默认 100%
            if let legacy = UserDefaults.standard.object(forKey: "glassUnderBlurEnabled") as? NSNumber {
                return legacy.boolValue ? 1 : 0
            }
            return 1
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: "glassUnderBlurStrength") }
    }

    /// 参与测试版：接收带 sparkle:channel=beta 的预发布版本（可能不稳定）；
    /// 关闭时只看默认通道（稳定版），已发布的稳定版更新不受影响
    static var betaChannel: Bool {
        get { UserDefaults.standard.bool(forKey: "betaChannelEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "betaChannelEnabled") }
    }
}
