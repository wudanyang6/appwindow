import AppKit

/// 全局面板外观设置
enum Theme {

    /// 背景装配代次：外观偏好（不透明度 / 着色量 / 模糊加强）变化时 +1。
    /// 面板容器与材质层跨会话复用，靠它判断复用缓存是否作废（否则改设置不生效，要重启应用）
    private(set) static var backgroundGeneration = 0

    static func invalidateBackgrounds() {
        backgroundGeneration += 1
    }

    /// 背景装配结果：
    /// - `contentHost`：内容应添加到的视图。**独立成层**、嵌在背景装配内部（暗色叠层内），
    ///   保证「清空 contentHost.subviews 重建内容」不会误删背景层
    ///   ——面板复用容器时正是这样清内容的
    /// - `materials`：本次装配添加的顶层视图（内容宿主嵌在其内），重建背景时整体移除即可完全卸载
    struct Background {
        let contentHost: NSView
        let materials: [NSView]
    }

    /// 给面板容器装配背景材质：毛玻璃模糊层（+ 可选加强层）+ 半透明暗色叠层。
    /// 容器由本函数设圆角与裁剪，材质层随容器尺寸自适应。
    /// （曾有过 NSGlassEffectView 分支：与背后模糊层互相抢采样、半径也不可控，已整体移除）
    @discardableResult
    static func installBackground(on container: NSView, cornerRadius: CGFloat,
                                  includeBackdropBlur: Bool = true) -> Background {
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        var materials: [NSView] = []
        // 背景整体不透明度（设置 → 通用 → 面板不透明度）：调低则背后内容透上来更多、模糊变淡
        let backgroundAlpha = CGFloat(Settings.panelAlpha)
        // 毛玻璃模糊层打底（behindWindow：采样窗口背后）
        let blur = blurView(fitting: container, cornerRadius: cornerRadius, alpha: backgroundAlpha)
        container.addSubview(blur)
        materials.append(blur)

        // 加强模糊：每层 withinWindow 把上一层的结果再糊一遍（半径 0 = 不加层）。
        // 设置窗口自身不装（普通窗口，糊了影响读设置）
        if includeBackdropBlur {
            let extraViews = BackdropBlur.makeExtraViews(
                radius: Tuning.backdropBlurRadius.value, cornerRadius: cornerRadius
            )
            for view in extraViews {
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                // 加强层跟着一起透：否则不透明的加强层会把半透明的基础层盖住
                view.alphaValue = backgroundAlpha
                container.addSubview(view)
                materials.append(view)
            }
        }

        // 半透明暗色叠在模糊之上、内容之下：降低亮度（原亮色叠层反而提亮，与系统观感不符）。
        // 着色量提成偏好（设置 → 通用 → 面板着色量）
        let tint = NSView(frame: container.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.cornerRadius = cornerRadius
        tint.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(CGFloat(Settings.panelTintAlpha)).cgColor
        container.addSubview(tint)
        materials.append(tint)
        // 内容宿主嵌在暗色叠层内：清空内容不波及背景层，卸载材质时随叠层一并移除
        return Background(contentHost: makeContentHost(fitting: tint), materials: materials)
    }

    /// 内容宿主层：铺满 parent 的透明子视图，叠在 parent 的背景填充之上。
    /// 独立成层（而非直接返回容器/垫层）是硬约束：面板复用容器时会
    /// 「清空 contentHost.subviews」重建内容，与背景层同层会把背景层一并清掉
    private static func makeContentHost(fitting parent: NSView) -> NSView {
        let host = NSView(frame: parent.bounds)
        host.autoresizingMask = [.width, .height]
        parent.addSubview(host)
        return host
    }

    /// 切换器「选中图标」高亮配色，按外观取分支：
    /// - 浅色模式：中灰 42% 填充（浅托盘上偏深、清晰可见）
    /// - 暗色模式：白 28% 填充
    /// 两种模式都不描边：描边在浅色下读成黑边、暗色下比填充更亮读成白圈（均实测反馈去掉）
    /// 返回具体色（非动态色）：图层颜色不随外观自动重解析，调用方按当前外观取一次即可，
    /// 面板每次显示都会重渲染
    static func switcherHighlightColor(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.28)
            : NSColor.gray.withAlphaComponent(0.42)
    }

    /// 窗口列表「选中行」高亮配色，按外观取分支：
    /// - 浅色模式：黑 20%（暗色块）
    /// - 暗色模式：白 18%（黑块在暗托盘上不可见）
    static func windowRowHighlightColor(for appearance: NSAppearance) -> NSColor {
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.20)
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
