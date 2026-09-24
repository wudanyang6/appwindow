import AppKit

/// 全局面板外观设置
enum Theme {

    /// 不使用玻璃效果时，毛玻璃材质层的不透明度（1.0 = 材质完全生效、最不透明）
    static let backgroundAlpha: CGFloat = 1.0
    /// 不使用玻璃效果时，毛玻璃之上再叠一层随系统深浅的半透明底色：降低透明度、
    /// 让后面窗口透上来的清晰内容更少，观感更实更「糊」（越大越不透明）
    static let nonGlassTintAlpha: CGFloat = 0.2
    /// 液态玻璃的黑色 tint 透明度：轻度压暗，提升面板上文字/图标对比（越大越暗）
    private static let glassTintAlpha: CGFloat = 0.1

    /// 给面板容器装配背景材质，返回所加的材质视图（供复用容器时保留、不重建）：
    /// - macOS 26+ 且未关闭玻璃：单层 NSGlassEffectView（.regular）+ 轻度黑色 tint 压暗
    /// - 否则（关闭玻璃 / macOS 14/15）：毛玻璃模糊层 + 半透明底色层（更实、更糊）
    /// 容器由本函数设圆角与裁剪，材质层随容器尺寸自适应
    @discardableResult
    static func installBackground(on container: NSView, cornerRadius: CGFloat) -> [NSView] {
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        guard #available(macOS 26.0, *), !Settings.glassDisabled else {
            // 毛玻璃模糊层打底
            let blur = blurView(fitting: container, cornerRadius: cornerRadius, alpha: backgroundAlpha)
            container.addSubview(blur)
            // 半透明底色叠在模糊之上、内容之下：降低透明度（后面窗口透得更少）
            let tint = NSView(frame: container.bounds)
            tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            tint.layer?.cornerRadius = cornerRadius
            tint.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(nonGlassTintAlpha).cgColor
            container.addSubview(tint)
            return [blur, tint]
        }

        // Liquid Glass 的聚焦/失焦样式由系统按窗口 key 状态渲染，无公开接口可干预；
        // 出问题时用菜单开关整体绕开（回到上面的纯毛玻璃分支）
        let glass = NSGlassEffectView(frame: container.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.tintColor = NSColor.black.withAlphaComponent(glassTintAlpha)
        container.addSubview(glass)
        return [glass]
    }

    /// 毛玻璃层：blendingMode 取 behindWindow 才能模糊面板后面的窗口内容。
    /// frame 必须按容器当前 bounds 给：autoresizingMask 只在容器尺寸变化时生效，
    /// 容器尺寸不变时留空 frame 的图层会一直保持 0×0
    private static func blurView(fitting container: NSView, cornerRadius: CGFloat, alpha: CGFloat) -> NSVisualEffectView {
        let blur = NSVisualEffectView(frame: container.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .menu
        blur.blendingMode = .behindWindow
        // 固定 .active：跟随窗口 key 状态会让非主屏面板在失焦时变成另一套亮度
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.alphaValue = alpha
        return blur
    }
}
