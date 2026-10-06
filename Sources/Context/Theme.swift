import AppKit

/// 全局面板外观设置
enum Theme {

    /// 不使用玻璃效果时，毛玻璃材质层的不透明度（1.0 = 材质完全生效、最不透明）
    static let backgroundAlpha: CGFloat = 1.0
    /// 不使用玻璃效果时，毛玻璃之上再叠一层随系统深浅的半透明底色：
    /// 降低透明度与亮度，让后面窗口透上来的清晰内容更少（越大越暗越「糊」）
    static let nonGlassTintAlpha: CGFloat = 0.12
    /// 液态玻璃的黑色 tint 透明度（实拍对比系统切换器校准）：Regular 轻、Clear 重
    private static let glassTintAlphaRegular: CGFloat = 0.10
    private static let glassTintAlphaClear: CGFloat = 0.18
    /// 玻璃之下的自适应不透明度垫层：把面板观感钉住、遮蔽底层内容（系统切换器观感的核心）
    private static let glassScrimAlpha: CGFloat = 0.5

    /// 背景装配结果：
    /// - `contentHost`：内容应添加到的视图。**独立成层**、嵌在背景装配内部（玻璃分支 = 垫层内、
    ///   毛玻璃分支 = 暗色叠层内），保证「清空 contentHost.subviews 重建内容」不会误删背景层
    ///   ——面板复用容器时正是这样清内容的，旧结构（内容与背景同层）曾导致 Clear 玻璃下
    ///   切换应用后下拉列表丢失垫层、可读性变差
    /// - `materials`：本次装配添加的顶层视图（内容宿主嵌在其内），重建背景时整体移除即可完全卸载
    struct Background {
        let contentHost: NSView
        let materials: [NSView]
    }

    /// 给面板容器装配背景材质，返回内容宿主与材质视图：
    /// - macOS 26+ 且未关闭玻璃：NSGlassEffectView（Regular/Clear），内容装入 contentView
    /// - 否则（关闭玻璃 / macOS 14/15）：毛玻璃模糊层 + 半透明底色层（更实、更糊）
    /// 容器由本函数设圆角与裁剪，材质层随容器尺寸自适应
    @discardableResult
    static func installBackground(on container: NSView, cornerRadius: CGFloat) -> Background {
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        let glassMode = Settings.glassMode
        guard #available(macOS 26.0, *), glassMode != .off else {
            // 毛玻璃模糊层打底
            let blur = blurView(fitting: container, cornerRadius: cornerRadius, alpha: backgroundAlpha)
            container.addSubview(blur)
            // 半透明暗色叠在模糊之上、内容之下：降低亮度（原亮色叠层反而提亮，与系统观感不符）
            let tint = NSView(frame: container.bounds)
            tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            tint.layer?.cornerRadius = cornerRadius
            tint.layer?.backgroundColor = NSColor.black
                .withAlphaComponent(nonGlassTintAlpha).cgColor
            container.addSubview(tint)
            // 内容宿主嵌在暗色叠层内：清空内容不波及背景层，卸载材质时随叠层一并移除
            return Background(contentHost: makeContentHost(fitting: tint), materials: [blur, tint])
        }

        // Liquid Glass 的聚焦/失焦样式由系统按窗口 key 状态渲染，无公开接口可干预；
        // 观感异常时在设置里切 Clear 或整体关闭（回到上面的纯毛玻璃分支）
        // 可配置强度的毛玻璃垫层：玻璃之下再叠一层 NSVisualEffectView，增强模糊、遮蔽底层内容
        // （争取「扭曲 + 强模糊」两者兼得，更接近系统切换器）。强度 = 垫层不透明度：
        // 半透明模糊与清晰底层混合，观感即模糊度可调；0 则不装配（更通透）
        var materials: [NSView] = []
        let underBlurStrength = Settings.glassUnderBlurStrength
        if underBlurStrength > 0 {
            let underBlur = blurView(fitting: container, cornerRadius: cornerRadius,
                                     alpha: CGFloat(underBlurStrength))
            container.addSubview(underBlur)
            materials.append(underBlur)
        }

        let glass = NSGlassEffectView(frame: container.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.style = glassMode == .clear ? .clear : .regular
        glass.cornerRadius = cornerRadius
        // 亮度对齐系统切换器（实拍对比校准）：玻璃本身偏亮，按档位加轻度黑色 tint
        switch glassMode {
        case .regular:
            glass.tintColor = NSColor.black.withAlphaComponent(glassTintAlphaRegular)
        case .clear:
            glass.tintColor = NSColor.black.withAlphaComponent(glassTintAlphaClear)
        case .off:
            glass.tintColor = nil
        }
        if #available(macOS 27.0, *) {
            // 面板/列表是交互容器，开启交互玻璃反馈（悬停/点击时玻璃有响应）
            glass.effectIsInteractive = true
        }
        // 内容宿主：放进 glass.contentView 才保证被嵌入玻璃内正确合成
        let host = NSView(frame: glass.bounds)
        host.autoresizingMask = [.width, .height]
        glass.contentView = host

        // 不透明度垫层：玻璃很透明，底层为深色页面时面板会整体变暗、深色文字不可辨；
        // 垫一层自适应底色（浅色模式浅灰、深色模式深灰）把面板观感钉住、并遮蔽底层文字，
        // 对齐系统切换器「材料稳定、不随底层反转」的特性
        let scrim = NSView(frame: host.bounds)
        scrim.autoresizingMask = [.width, .height]
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(glassScrimAlpha).cgColor
        host.addSubview(scrim)

        // 内容宿主嵌在垫层内（与毛玻璃分支同构）：清空内容不波及垫层；
        // 仍在 glass.contentView 内，保证内容被放进玻璃内合成（头文件语义）
        let contentHost = makeContentHost(fitting: scrim)

        container.addSubview(glass)
        materials.append(glass)
        return Background(contentHost: contentHost, materials: materials)
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
