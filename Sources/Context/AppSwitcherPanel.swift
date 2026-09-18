import AppKit

// 文件级布局常量
private enum SwitcherMetrics {
    static let iconSizeMax: CGFloat = 154
    static let iconGap: CGFloat = 0
    static let listWidthMin: CGFloat = 180
    static let listWidthMax: CGFloat = 360
    static let maxListRows = 8
    static let edgeInset: CGFloat = 14
    // 图标面板与屏幕两侧的留白，避免面板顶满屏幕
    static let panelSideMargin: CGFloat = 48
    static let panelGap: CGFloat = 6
    static let cornerRadius: CGFloat = 18
    static let rowHeight: CGFloat = 34
    static let titleFont = NSFont.systemFont(ofSize: 13)
}

/// cmd+tab 切换面板，**每个屏幕各显示一份**（状态跨屏同步）：
/// - 图标行主面板（图标底色高亮，各屏自身居中且位置固定）
/// - 窗口列表面板（宽度按内容自适应，挂在高亮图标正下方，支持连续滚动）
/// 背景材质跟随系统深浅外观。非激活、不抢键盘焦点，键盘交互由 EventTapManager 驱动。
final class AppSwitcherPanel {

    private var iconPanels: [NonKeyPanel] = []
    private var listPanels: [NonKeyPanel] = []
    // 每屏一套行视图（index 与窗口索引一致），高亮切换遍历所有屏
    private var rowViewsPerScreen: [[WindowRowView]] = []
    private var arrowsPerScreen: [(up: NSImageView, down: NSImageView)] = []

    private var apps: [SwitcherApp] = []
    private var currentWindows: [WindowItem] = []
    private var appIndex = 0
    private var windowIndex = 0

    private let listScroller = ListScrollController(rowHeight: SwitcherMetrics.rowHeight)

    private var onPickApp: ((Int) -> Void)?
    private var onHoverApp: ((Int) -> Void)?
    private var onPickWindow: ((Int) -> Void)?
    private var onHoverWindow: ((Int) -> Void)?
    private var onScrollApp: ((Int) -> Void)?

    func show(apps: [SwitcherApp], appIndex: Int, windows: [WindowItem], windowIndex: Int,
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
        self.onPickApp = onPickApp
        self.onHoverApp = onHoverApp
        self.onPickWindow = onPickWindow
        self.onHoverWindow = onHoverWindow
        self.onScrollApp = onScrollApp

        for _ in NSScreen.screens {
            let iconPanel = NonKeyPanel(contentRect: .zero,
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
            let listPanel = NonKeyPanel(contentRect: .zero,
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
            configure(iconPanel)
            configure(listPanel)
            iconPanels.append(iconPanel)
            listPanels.append(listPanel)
        }

        render()

        // 无入场动画，优先性能；列表面板显隐由 render 决定
        iconPanels.forEach { $0.orderFrontRegardless() }
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

    func dismiss() {
        iconPanels.forEach { $0.orderOut(nil) }
        listPanels.forEach { $0.orderOut(nil) }
        iconPanels = []
        listPanels = []
        rowViewsPerScreen = []
        arrowsPerScreen = []
        apps = []
        currentWindows = []
        onPickApp = nil
        onPickWindow = nil
        onHoverWindow = nil
        onScrollApp = nil
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

    /// 容器承载内容与滚轮响应；毛玻璃作为容器内的独立子层，透明度可单独调节
    private func makeContainer(width: CGFloat, height: CGFloat) -> ScrollContainerView {
        let container = ScrollContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.cornerRadius = SwitcherMetrics.cornerRadius
        container.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = SwitcherMetrics.cornerRadius
        effect.alphaValue = Theme.backgroundAlpha
        container.addSubview(effect)
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
        guard !iconPanels.isEmpty else { return }

        let total = currentWindows.count
        let shownCount = min(SwitcherMetrics.maxListRows, total)
        let clipHeight = CGFloat(shownCount) * SwitcherMetrics.rowHeight
        let contentHeight = CGFloat(total) * SwitcherMetrics.rowHeight

        var allRows: [[WindowRowView]] = []
        var scrollContents: [NSView] = []
        var allArrows: [(up: NSImageView, down: NSImageView)] = []

        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            guard screenIndex < iconPanels.count, screenIndex < listPanels.count else { continue }

            let (highlightedCenter, iconPanelBottom) = renderIconPanel(on: screen, panel: iconPanels[screenIndex])

            if let (rows, content, arrows) = renderListPanel(
                on: screen, panel: listPanels[screenIndex],
                topY: iconPanelBottom,
                clipHeight: clipHeight, contentHeight: contentHeight,
                highlightedCenter: highlightedCenter
            ) {
                allRows.append(rows)
                scrollContents.append(content)
                allArrows.append(arrows)
            }
        }

        rowViewsPerScreen = allRows
        arrowsPerScreen = allArrows
        listScroller.onOffsetChanged = { [weak self] in self?.updateScrollArrows() }
        listScroller.attach(contents: scrollContents,
                            contentHeight: contentHeight, clipHeight: clipHeight)
        updateScrollArrows()
    }

    /// 渲染图标主面板，各屏按自身尺寸布局；返回高亮图标中心横坐标与面板底部 y（该屏坐标系）
    private func renderIconPanel(on screen: NSScreen, panel: NonKeyPanel) -> (highlightedCenter: CGFloat, bottomY: CGFloat) {
        let visibleFrame = screen.visibleFrame

        // 单行布局：图标大小随应用数量缩放；达到上限后不再放大，
        // 面板宽度始终紧贴图标总宽（不设尺寸下限，应用极多时面板也不会超出屏幕）
        let count = max(CGFloat(apps.count), 1)
        let availableWidth = visibleFrame.width - SwitcherMetrics.panelSideMargin * 2
        let slot = min(SwitcherMetrics.iconSizeMax, availableWidth / count)

        let iconPanelWidth = slot * count + SwitcherMetrics.edgeInset * 2
        let iconPanelHeight = slot + SwitcherMetrics.edgeInset * 2

        let background = makeContainer(width: iconPanelWidth, height: iconPanelHeight)
        background.onScrollStep = { [weak self] in self?.onScrollApp?($0) }

        for (index, app) in apps.enumerated() {
            let slotView = IconSlotView(index: index, icon: app.icon,
                                        iconSize: slot, slotSize: slot,
                                        onHover: { [weak self] in self?.onHoverApp?($0) },
                                        onClick: { [weak self] in self?.onPickApp?($0) })
            slotView.frame = NSRect(x: SwitcherMetrics.edgeInset + CGFloat(index) * slot,
                                    y: SwitcherMetrics.edgeInset,
                                    width: slot, height: slot)
            slotView.setSelected(index == appIndex)
            background.addSubview(slotView)
        }

        // 图标面板自身垂直居中于该屏且位置固定，列表高度变化不影响主面板位置
        let iconPanelX = visibleFrame.midX - iconPanelWidth / 2
        let iconPanelTop = visibleFrame.midY + iconPanelHeight / 2
        apply(background, to: panel, x: iconPanelX, topY: iconPanelTop)

        let highlightedCenter = iconPanelX + SwitcherMetrics.edgeInset
            + CGFloat(appIndex) * slot + slot / 2

        return (highlightedCenter, iconPanelTop - iconPanelHeight)
    }

    /// 渲染窗口列表面板；无窗口返回 nil（面板隐藏）
    private func renderListPanel(on screen: NSScreen, panel: NonKeyPanel,
                                 topY: CGFloat,
                                 clipHeight: CGFloat, contentHeight: CGFloat,
                                 highlightedCenter: CGFloat)
        -> (rows: [WindowRowView], scrollContent: NSView,
            arrows: (up: NSImageView, down: NSImageView))? {

        let total = currentWindows.count
        guard total > 0, let appIcon = apps.indices.contains(appIndex) ? apps[appIndex].icon : nil else {
            panel.orderOut(nil)
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
                                    width: listWidth,
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
        apply(background, to: panel, x: x, topY: topY - SwitcherMetrics.panelGap)

        // 面板可能因上一个应用无窗口而被 orderOut，内容就绪后必须重新显示
        if !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        return (rows, content, (up, down))
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
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void

    init(index: Int, icon: NSImage?, iconSize: CGFloat, slotSize: CGFloat,
         onHover: @escaping (Int) -> Void,
         onClick: @escaping (Int) -> Void) {
        self.index = index
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 14

        let iconView = NSImageView(frame: NSRect(x: (slotSize - iconSize) / 2,
                                                 y: (slotSize - iconSize) / 2,
                                                 width: iconSize, height: iconSize))
        iconView.image = icon
        // 系统图标的 NSImage 尺寸常小于槽位（如 128），proportionallyDown 不会放大，
        // 必须用 upOrDown 让图标真正撑满槽位
        iconView.imageScaling = .scaleProportionallyUpOrDown
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

    override func mouseDown(with event: NSEvent) {
        onClick(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(index)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
