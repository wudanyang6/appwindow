import AppKit

// 文件级布局常量
private enum SwitcherMetrics {
    static let iconSizeMax: CGFloat = 154
    // 图标槽位之间的间距
    static let iconGap: CGFloat = 12
    static let listWidthMin: CGFloat = 180
    static let listWidthMax: CGFloat = 360
    static let maxListRows = 8
    // 窗口列表面板与内容行的内边距
    static let edgeInset: CGFloat = 14
    // 图标行托盘的内边距（独立于列表，四周留白更大）
    static let iconInset: CGFloat = 24
    // 图标面板与屏幕两侧的留白，避免面板顶满屏幕
    static let panelSideMargin: CGFloat = 48
    static let panelGap: CGFloat = 6
    // 所有面板（图标行托盘与窗口列表）统一圆角
    static let cornerRadius: CGFloat = 26
    static let rowHeight: CGFloat = 34
    static let titleFont = NSFont.systemFont(ofSize: 13)
}

/// cmd+tab 切换面板，**每个屏幕各显示一份**（状态跨屏同步）：
/// - 图标行主面板（图标底色高亮，各屏自身居中且位置固定）
/// - 窗口列表（宽度按内容自适应，挂在高亮图标正下方，支持连续滚动）
/// 两者合并在**同一个窗口**里（union 布局）：单窗口只有一份 key 状态，
/// 两块液态玻璃同窗即同聚焦。背景材质跟随系统深浅外观。非激活、不抢键盘焦点，
/// 键盘交互由 EventTapManager 驱动。
final class AppSwitcherPanel {

    // 每屏一个合并面板（图标行 + 下挂列表同窗）
    private var panels: [NonKeyPanel] = []
    // 每屏一套行视图（index 与窗口索引一致），高亮切换遍历所有屏
    private var rowViewsPerScreen: [[WindowRowView]] = []
    private var arrowsPerScreen: [(up: NSImageView, down: NSImageView)] = []

    private var apps: [SwitcherApp] = []
    private var currentWindows: [WindowItem] = []
    private var appIndex = 0
    private var windowIndex = 0
    // dock 角标（未读数），与 apps 索引对齐；异步刷新后经 updateBadges 更新视图
    private var badges: [String?] = []
    // 每屏一套图标槽位（index 与应用索引一致），角标刷新需要持有引用
    private var iconSlotsPerScreen: [[IconSlotView]] = []

    private let listScroller = ListScrollController(rowHeight: SwitcherMetrics.rowHeight)

    private var onPickApp: ((Int) -> Void)?
    private var onHoverApp: ((Int) -> Void)?
    private var onPickWindow: ((Int) -> Void)?
    private var onHoverWindow: ((Int) -> Void)?
    private var onScrollApp: ((Int) -> Void)?
    private var hoverGate: MouseHoverGate?

    func show(apps: [SwitcherApp], appIndex: Int, windows: [WindowItem], windowIndex: Int,
              badges: [String?],
              onPickApp: @escaping (Int) -> Void,
              onHoverApp: @escaping (Int) -> Void,
              onPickWindow: @escaping (Int) -> Void,
              onHoverWindow: @escaping (Int) -> Void,
              onScrollApp: @escaping (Int) -> Void) {
        dismiss()

        self.apps = apps
        self.appIndex = appIndex
        self.currentWindows = windows
        self.windowIndex = windowIndex
        self.badges = badges
        self.onPickApp = onPickApp
        self.onHoverApp = onHoverApp
        self.onPickWindow = onPickWindow
        self.onHoverWindow = onHoverWindow
        self.onScrollApp = onScrollApp
        hoverGate = MouseHoverGate()

        // 跨屏单窗：液态玻璃的聚焦渲染跟随窗口 key 状态，而一个 app 只有一个
        // key window；每屏各开一窗时非 key 屏的玻璃会退化为失活样式。单窗承载
        // 所有屏的图标行与下挂列表，makeKey 一次，全部玻璃共享聚焦态。
        // 窗口覆盖所有屏可视区域的联合矩形（render 里计算），空白区经 PanelRootView 穿透
        let panel = NonKeyPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("switcher-0")
        configure(panel)
        panels = [panel]

        render()

        // 无入场动画，优先性能
        panel.orderFrontRegardless()
        // makeKey 系调用实测必然隐式激活 App（yieldActivation 也无法避免；
        // 面板生命周期内短暂 active，关闭即失活，接受）。
        // 面板键盘输入本就来自 EventTap，不依赖窗口系统派发
        panel.makeKeyAndOrderFront(nil)
        DiagLog.log("panel", "switcher makeKey: isKeyWindow=\(panel.isKeyWindow) appActive=\(NSApp.isActive)")
    }

    /// tab 移动到另一个应用；windows 由调用方传入（值语义数组，面板不与 manager 共享状态）
    func selectApp(index: Int, windows: [WindowItem], selectedWindow: Int) {
        guard apps.indices.contains(index) else { return }
        appIndex = index
        currentWindows = windows
        windowIndex = selectedWindow
        render()
    }

    func selectWindow(index: Int) {
        guard currentWindows.indices.contains(index) else { return }
        let previous = windowIndex
        windowIndex = index

        if previous != index {
            for rows in rowViewsPerScreen {
                if rows.indices.contains(previous) { rows[previous].setHighlighted(false) }
                if rows.indices.contains(index) { rows[index].setHighlighted(true) }
            }
        }
        listScroller.ensureVisible(index: index, total: currentWindows.count)
    }

    /// 选择面板显示期间异步刷出的新角标，只更新槽位视图不重渲染
    func updateBadges(_ badges: [String?]) {
        self.badges = badges
        for slots in iconSlotsPerScreen {
            for (index, slot) in slots.enumerated() where badges.indices.contains(index) {
                slot.setBadge(badges[index])
            }
        }
    }

    func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        rowViewsPerScreen = []
        arrowsPerScreen = []
        iconSlotsPerScreen = []
        apps = []
        currentWindows = []
        badges = []
        onPickApp = nil
        onPickWindow = nil
        onHoverWindow = nil
        onScrollApp = nil
        hoverGate = nil
    }
}

// MARK: - 渲染与布局

private extension AppSwitcherPanel {

    private func configure(_ panel: NSPanel) {
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
    }

    /// 容器承载内容与滚轮响应；背景层作为容器内的独立子视图（先加背景再加内容）。
    /// 所有面板统一玻璃配置：毛玻璃打底提供模糊（玻璃 API 无模糊参数，alpha 控强度），
    /// clear 液态玻璃质感层在上，黑 tint 统一亮度
    private func makeContainer(width: CGFloat, height: CGFloat) -> ScrollContainerView {
        let container = ScrollContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = SwitcherMetrics.cornerRadius
        container.layer?.masksToBounds = true

        if #available(macOS 26.0, *) {
            // Liquid Glass：聚焦/失焦样式由系统按窗口 key 状态渲染（见 show() 的 makeKey）
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.autoresizingMask = [.width, .height]
            glass.style = .clear
            glass.cornerRadius = SwitcherMetrics.cornerRadius
            glass.tintColor = NSColor.black.withAlphaComponent(0.15)
            let blur = NSVisualEffectView(frame: container.bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .menu
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.alphaValue = 0.75
            container.addSubview(blur, positioned: .below, relativeTo: glass)
            container.addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = SwitcherMetrics.cornerRadius
            effect.alphaValue = Theme.backgroundAlpha
            container.addSubview(effect)
        }
        return container
    }

    private func apply(_ background: NSView, to panel: NSPanel, x: CGFloat, topY: CGFloat) {
        // setContentView 会把视图 resize 到窗口当前内容尺寸（初始为 zero），
        // 因此必须先保存目标尺寸，替换后再由 setContentSize 恢复
        let size = background.frame.size
        panel.contentView = background
        panel.setContentSize(size)
        panel.setFrameOrigin(CGPoint(x: x, y: topY - size.height))
    }

    private func render() {
        guard let panel = panels.first, let hoverGate else { return }

        let total = currentWindows.count
        let shownCount = min(SwitcherMetrics.maxListRows, total)
        let clipHeight = CGFloat(shownCount) * SwitcherMetrics.rowHeight
        let contentHeight = CGFloat(total) * SwitcherMetrics.rowHeight

        // 窗口覆盖所有屏可视区域的联合矩形（show 里创建的跨屏单窗），
        // 各屏内容按屏幕全局坐标布局后平移进窗口
        let screens = NSScreen.screens
        let bounds = screens.map(\.visibleFrame).reduce(screens[0].visibleFrame) { $0.union($1) }
        let root = PanelRootView(frame: NSRect(origin: .zero, size: bounds.size))

        var allRows: [[WindowRowView]] = []
        var scrollContents: [NSView] = []
        var allArrows: [(up: NSImageView, down: NSImageView)] = []
        var allSlots: [[IconSlotView]] = []

        for screen in screens {
            let icon = layoutIconPanel(on: screen, hoverGate: hoverGate)
            let list = layoutListPanel(on: screen, iconFrame: icon.frame,
                                       highlightedCenter: icon.highlightedCenter,
                                       clipHeight: clipHeight, contentHeight: contentHeight,
                                       hoverGate: hoverGate)
            // 图标行与列表的容器平移进跨屏单窗：屏幕全局坐标 → 窗口内相对坐标，
            // 间隙保持透明（与各屏独立开窗时的屏幕缝隙视觉等价）
            icon.container.frame = icon.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            root.addSubview(icon.container)
            if let list {
                list.container.frame = list.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                root.addSubview(list.container)
                allRows.append(list.rows)
                scrollContents.append(list.scrollContent)
                allArrows.append(list.arrows)
            }
            allSlots.append(icon.slots)
        }

        rowViewsPerScreen = allRows
        arrowsPerScreen = allArrows
        iconSlotsPerScreen = allSlots
        listScroller.onOffsetChanged = { [weak self] in self?.updateScrollArrows() }
        listScroller.attach(contents: scrollContents,
                            contentHeight: contentHeight, clipHeight: clipHeight)
        updateScrollArrows()

        // 图标行屏幕位置恒定：列表高度变化只改变窗口下方内容，不挪图标行
        apply(root, to: panel, x: bounds.minX, topY: bounds.maxY)
    }

    /// 布局图标行（不落窗口）：返回容器视图、屏幕坐标矩形、槽位视图与高亮图标中心横坐标
    private func layoutIconPanel(on screen: NSScreen, hoverGate: MouseHoverGate)
        -> (container: ScrollContainerView, frame: NSRect,
            slots: [IconSlotView], highlightedCenter: CGFloat) {
        let visibleFrame = screen.visibleFrame

        // 单行布局：图标大小随应用数量缩放；达到上限后不再放大，
        // 面板宽度始终紧贴图标总宽（不设尺寸下限，应用极多时面板也不会超出屏幕）
        let count = max(CGFloat(apps.count), 1)
        let availableWidth = visibleFrame.width - SwitcherMetrics.panelSideMargin * 2
        let slot = min(SwitcherMetrics.iconSizeMax,
                       (availableWidth - SwitcherMetrics.iconGap * (count - 1)) / count)

        let iconPanelWidth = slot * count + SwitcherMetrics.iconGap * (count - 1)
            + SwitcherMetrics.iconInset * 2
        let iconPanelHeight = slot + SwitcherMetrics.iconInset * 2

        let background = makeContainer(width: iconPanelWidth, height: iconPanelHeight)
        background.onScrollStep = { [weak self] in self?.onScrollApp?($0) }

        var slots: [IconSlotView] = []
        for (index, app) in apps.enumerated() {
            let slotView = IconSlotView(index: index, icon: app.icon,
                                        iconSize: slot, slotSize: slot,
                                        hoverGate: hoverGate,
                                        onHover: { [weak self] in self?.onHoverApp?($0) },
                                        onClick: { [weak self] in self?.onPickApp?($0) })
            slotView.frame = NSRect(x: SwitcherMetrics.iconInset + CGFloat(index) * (slot + SwitcherMetrics.iconGap),
                                    y: SwitcherMetrics.iconInset,
                                    width: slot, height: slot)
            slotView.setSelected(index == appIndex)
            slotView.setBadge(badges.indices.contains(index) ? badges[index] : nil)
            background.addSubview(slotView)
            slots.append(slotView)
        }

        // 图标面板自身垂直居中于该屏且位置固定
        let iconPanelX = visibleFrame.midX - iconPanelWidth / 2
        let iconPanelTop = visibleFrame.midY + iconPanelHeight / 2

        let highlightedCenter = iconPanelX + SwitcherMetrics.iconInset
            + CGFloat(appIndex) * (slot + SwitcherMetrics.iconGap) + slot / 2

        let frame = NSRect(x: iconPanelX, y: iconPanelTop - iconPanelHeight,
                           width: iconPanelWidth, height: iconPanelHeight)
        return (background, frame, slots, highlightedCenter)
    }

    /// 布局窗口列表（不落窗口）：挂在高亮图标正下方，无窗口返回 nil（列表不显示）
    private func layoutListPanel(on screen: NSScreen, iconFrame: NSRect,
                                 highlightedCenter: CGFloat,
                                 clipHeight: CGFloat, contentHeight: CGFloat,
                                 hoverGate: MouseHoverGate)
        -> (container: ScrollContainerView, frame: NSRect,
            rows: [WindowRowView], scrollContent: NSView,
            arrows: (up: NSImageView, down: NSImageView))? {

        let total = currentWindows.count
        guard total > 0, let appIcon = apps.indices.contains(appIndex) ? apps[appIndex].icon : nil else {
            return nil
        }

        // 列表宽度按全部窗口的最长标题自适应，滚动露出旧行时宽度同样合适
        let maxTitleWidth = currentWindows
            .map { ($0.title as NSString).size(withAttributes: [.font: SwitcherMetrics.titleFont]).width }
            .max() ?? 0
        let listWidth = min(SwitcherMetrics.listWidthMax,
                            max(SwitcherMetrics.listWidthMin, maxTitleWidth + 54))

        let height = clipHeight + SwitcherMetrics.edgeInset * 2
        // 面板宽度 = 行宽 + 两侧边距；行从 edgeInset 起、宽 listWidth，缺了边距会让高亮块溢出背景右缘
        let panelWidth = listWidth + SwitcherMetrics.edgeInset * 2
        let background = makeContainer(width: panelWidth, height: height)
        background.onScrollRaw = { [weak self] in self?.listScroller.scroll(by: $0) }

        // 裁剪视口 + 承载全部行的内容视图：滚动只平移内容视图，不重建任何行
        let clip = NSView(frame: NSRect(x: SwitcherMetrics.edgeInset, y: SwitcherMetrics.edgeInset,
                                        width: listWidth, height: clipHeight))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        background.addSubview(clip)

        let content = NSView(frame: NSRect(x: 0, y: clipHeight - contentHeight,
                                           width: listWidth, height: contentHeight))
        var rows: [WindowRowView] = []
        for (index, item) in currentWindows.enumerated() {
            let row = WindowRowView(index: index, icon: appIcon, title: item.title,
                                    width: listWidth, hoverGate: hoverGate,
                                    onHover: { [weak self] in self?.onHoverWindow?($0) },
                                    onClick: { [weak self] in self?.onPickWindow?($0) })
            row.frame = NSRect(x: 0,
                               y: CGFloat(total - 1 - index) * SwitcherMetrics.rowHeight,
                               width: listWidth,
                               height: SwitcherMetrics.rowHeight)
            row.setHighlighted(index == windowIndex)
            content.addSubview(row)
            rows.append(row)
        }
        clip.addSubview(content)

        let arrowX = panelWidth / 2 - 6
        let up = NSImageView.scrollIndicator(symbol: "chevron.up", x: arrowX, y: height - 13)
        let down = NSImageView.scrollIndicator(symbol: "chevron.down", x: arrowX, y: 1)
        background.addSubview(up)
        background.addSubview(down)

        // 挂在高亮图标正下方，越出屏幕时夹回该屏可见范围
        let visibleFrame = screen.visibleFrame
        var x = highlightedCenter - panelWidth / 2
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - panelWidth))
        let frame = NSRect(x: x,
                           y: iconFrame.minY - SwitcherMetrics.panelGap - height,
                           width: panelWidth, height: height)

        return (background, frame, rows, content, (up, down))
    }

    private func updateScrollArrows() {
        for arrows in arrowsPerScreen {
            arrows.up.isHidden = !listScroller.hasMoreAbove
            arrows.down.isHidden = !listScroller.hasMoreBelow
        }
    }
}

// MARK: - 子视图

private final class IconSlotView: NSView {

    private let index: Int
    private let hoverGate: MouseHoverGate
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void
    private var badgeView: BadgeView?
    private let iconView: NSImageView

    init(index: Int, icon: NSImage?, iconSize: CGFloat, slotSize: CGFloat,
         hoverGate: MouseHoverGate,
         onHover: @escaping (Int) -> Void,
         onClick: @escaping (Int) -> Void) {
        self.index = index
        self.hoverGate = hoverGate
        self.onHover = onHover
        self.onClick = onClick

        let iconView = NSImageView(frame: NSRect(x: (slotSize - iconSize) / 2,
                                                 y: (slotSize - iconSize) / 2,
                                                 width: iconSize, height: iconSize))
        iconView.image = icon
        // 系统图标的 NSImage 尺寸常小于槽位（如 128），proportionallyDown 不会放大，
        // 必须用 upOrDown 让图标真正撑满槽位
        iconView.imageScaling = .scaleProportionallyUpOrDown
        self.iconView = iconView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 14
        addSubview(iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        // 选中样式为图标底色高亮（accent 半透明圆角块），未选中透明
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
            : nil
    }

    /// 角标放图标视觉内容的右上角；badge 为 nil 时移除。
    /// 调用前提：frame 已定，因此初始渲染由外部在设完 frame 后调用
    func setBadge(_ text: String?) {
        badgeView?.removeFromSuperview()
        badgeView = nil
        guard let text, !text.isEmpty, frame.width > 0 else { return }

        let badge = BadgeView(text: text)
        // 内收骑角：badge 中心压在图案右上角偏左下 1/4 处，只外突 1/4
        // （整半骑角视觉上太飘，见实测反馈）
        let content = iconContentRect
        badge.frame.origin = NSPoint(x: content.maxX - badge.frame.width * 0.75,
                                     y: content.maxY - badge.frame.height * 0.75)
        addSubview(badge)
        badgeView = badge
    }

    /// 图标的视觉内容区：等比缩放居中后，按 alignmentRect（AppKit 排除图标透明边）
    /// 或不透明像素边界（alpha 扫描，alignmentRect 多数图标未设置时的兜底）计算。
    /// 图标画布常见 20% 透明边（macOS 图标网格规范），骑画布角会让角标悬空在
    /// 图案外的透明区上——实测 alignmentRect 恒为全幅，alpha 扫描才是可靠来源
    private var iconContentRect: NSRect {
        let f = iconView.frame
        guard let image = iconView.image,
              image.size.width > 0, image.size.height > 0 else { return f }

        let scale = min(f.width / image.size.width, f.height / image.size.height)
        let drawnWidth = image.size.width * scale
        let drawnHeight = image.size.height * scale
        let drawnOrigin = NSPoint(x: (f.width - drawnWidth) / 2, y: (f.height - drawnHeight) / 2)

        let aligned = image.alignmentRect
        let normalized: CGRect
        if aligned.width > 0, aligned.height > 0,
           aligned != CGRect(origin: .zero, size: image.size) {
            normalized = CGRect(x: aligned.minX / image.size.width,
                                y: aligned.minY / image.size.height,
                                width: aligned.width / image.size.width,
                                height: aligned.height / image.size.height)
        } else {
            normalized = Self.opaqueBounds(of: image)
        }
        return NSRect(x: drawnOrigin.x + normalized.minX * drawnWidth,
                      y: drawnOrigin.y + normalized.minY * drawnHeight,
                      width: normalized.width * drawnWidth,
                      height: normalized.height * drawnHeight)
    }

    /// 扫描图像不透明内容的归一化边界（0-1 坐标，左下原点）：绘制 64x64 缩略图
    /// 后逐像素查 alpha 阈值，约万次循环内完成，渲染期调用无感
    private static func opaqueBounds(of image: NSImage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return full
        }

        let side = 64
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return full }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        var minX = side, minY = side, maxX = -1, maxY = -1
        let rowStride = side * 4
        for row in 0..<side {
            let base = row * rowStride
            for col in 0..<side {
                // alpha 阈值 0.3：排除抗锯齿边缘与半透明装饰
                if pixels[base + col * 4 + 3] > 77 {
                    if col < minX { minX = col }
                    if col > maxX { maxX = col }
                    if row < minY { minY = row }
                    if row > maxY { maxY = row }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return full }

        let unit = CGFloat(side)
        return CGRect(x: CGFloat(minX) / unit, y: CGFloat(minY) / unit,
                      width: CGFloat(maxX - minX + 1) / unit,
                      height: CGFloat(maxY - minY + 1) / unit)
    }

    override func mouseDown(with event: NSEvent) {
        onClick(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        handleHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        handleHover(event)
    }

    private func handleHover(_ event: NSEvent) {
        guard let window,
              hoverGate.hasMoved(inWindow: event.locationInWindow, of: window) else { return }
        onHover(index)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Dock 同款未读角标：红底白字胶囊，宽度随文字自适应（"1" 是圆点、"99+" 加宽）
private final class BadgeView: NSView {

    init(text: String) {
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let height: CGFloat = 24
        let width = max(height, textWidth + 14)

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = height / 2

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (height - 19) / 2, width: width, height: 19)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
