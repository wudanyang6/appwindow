import AppKit

// 文件级布局常量
private enum SwitcherMetrics {
    static let iconSizeMax: CGFloat = 154
    // 图标槽位之间的间距
    static let iconGap: CGFloat = 12
    static let listWidthMin: CGFloat = 180
    static let listWidthMax: CGFloat = 360
    static let maxListRows = 8
    // 下拉窗口列表的内边距：收窄使托盘更紧凑（与 cmd+` 面板一致）
    static let edgeInset: CGFloat = 8
    // 图标行托盘的内边距（独立于列表，四周留白更大）
    static let iconInset: CGFloat = 24
    // 图标面板与屏幕两侧的留白，避免面板顶满屏幕
    static let panelSideMargin: CGFloat = 48
    static let panelGap: CGFloat = 6
    // 图标行托盘圆角
    static let cornerRadius: CGFloat = 26
    // 下拉窗口列表托盘圆角：与行高亮圆角同心（高亮 8 + 距托盘边 edgeInset 8 = 16），视觉一致
    static let listCornerRadius: CGFloat = 16
    static let rowHeight: CGFloat = 34
    static let titleFont = NSFont.systemFont(ofSize: 13)
    // 选中应用名称：托盘内图标下方的文字（字号 + 图标与文字之间的间距）
    static let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let nameGap: CGFloat = 3
    // 名称距托盘底边的留白：同时也是图标上方留白（居中对称），调大即整体托盘变高
    static let nameBottomInset: CGFloat = 5
}

/// cmd+tab 切换面板，**每个屏幕各显示一份**（状态跨屏同步）：
/// - 图标行主面板（图标底色高亮，各屏自身居中且位置固定；选中图标下方在托盘内显示应用名）
/// - 窗口列表（宽度按内容自适应，挂在图标行下方，支持连续滚动）
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
    // 当前高亮应用选中的窗口；nil = 未选（列表无高亮行，提交走应用级激活）
    private var windowIndex: Int?
    // dock 角标（未读数），与 apps 索引对齐；异步刷新后经 updateBadges 更新视图
    private var badges: [String?] = []
    // 每屏一套图标槽位（index 与应用索引一致），角标刷新需要持有引用
    private var iconSlotsPerScreen: [[IconSlotView]] = []
    // 每屏一层角标高层（叠在图标之上，防止相邻图标遮挡角标）
    private var badgeOverlaysPerScreen: [NSView] = []
    // 每屏窗口列表的屏幕坐标矩形；全局滚轮据此判断「指针是否在列表上」（悬停列表才滚列表）
    private var listFramesPerScreen: [NSRect] = []
    // 每屏图标槽位视图跨渲染复用：切换应用不重建图标视图（避免重图标 iDev 每次重绘闪烁，也更快）
    private var reusableSlotsPerScreen: [[IconSlotView]] = []

    private let listScroller = ListScrollController(rowHeight: SwitcherMetrics.rowHeight)

    private var onPickApp: ((Int) -> Void)?
    private var onHoverApp: ((Int) -> Void)?
    private var onPickWindow: ((Int) -> Void)?
    private var onHoverWindow: ((Int) -> Void)?
    private var onScrollApp: ((Int) -> Void)?
    // 透明间隙（union 窗口内、容器之外）被点击时取消面板
    private var onCancel: (() -> Void)?
    private var hoverGate: MouseHoverGate?

    func show(apps: [SwitcherApp], appIndex: Int, windows: [WindowItem], windowIndex: Int?,
              badges: [String?],
              onPickApp: @escaping (Int) -> Void,
              onHoverApp: @escaping (Int) -> Void,
              onPickWindow: @escaping (Int) -> Void,
              onHoverWindow: @escaping (Int) -> Void,
              onScrollApp: @escaping (Int) -> Void,
              onCancel: @escaping () -> Void) {
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
        self.onCancel = onCancel
        hoverGate = MouseHoverGate()

        for (screenIndex, _) in NSScreen.screens.enumerated() {
            let panel = NonKeyPanel(contentRect: .zero,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("switcher-\(screenIndex)")
            configure(panel)
            panels.append(panel)
        }

        render()

        // 无入场动画，优先性能
        panels.forEach { $0.orderFrontRegardless() }
        // 首屏面板成 key，其他屏由 hover 激活（单 key 窗口模型：app 同一时刻
        // 只有一个 key window，跨屏玻璃聚焦靠 hover 转正 key 切换）。
        // makeKey 系调用实测必然隐式激活 App（面板生命周期内短暂 active，接受）
        panels.first?.makeKeyAndOrderFront(nil)
        DiagLog.log("panel", "switcher makeKey: isKeyWindow=\(panels.first?.isKeyWindow ?? false) appActive=\(NSApp.isActive)")
    }

    /// tab 移动到另一个应用；windows 由调用方传入（值语义数组，面板不与 manager 共享状态）
    func selectApp(index: Int, windows: [WindowItem], selectedWindow: Int?) {
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
                if let previous, rows.indices.contains(previous) { rows[previous].setHighlighted(false) }
                if rows.indices.contains(index) { rows[index].setHighlighted(true) }
            }
        }
        listScroller.ensureVisible(index: index, total: currentWindows.count)
    }

    /// 选择面板显示期间异步刷出的新角标，只重画角标高层不重渲染
    func updateBadges(_ badges: [String?]) {
        self.badges = badges
        for (screenIndex, overlay) in badgeOverlaysPerScreen.enumerated()
            where iconSlotsPerScreen.indices.contains(screenIndex) {
            placeBadges(on: overlay, slots: iconSlotsPerScreen[screenIndex])
        }
    }

    /// 屏幕坐标点是否落在任一屏的窗口列表上（仅列表区，不含图标行/间隙）。
    /// 全局滚轮据此决定：在列表上滚列表，否则切应用
    func listContains(_ screenPoint: NSPoint) -> Bool {
        listFramesPerScreen.contains { $0.contains(screenPoint) }
    }

    /// 供全局滚轮驱动：滚动窗口列表（不依赖面板视图自己收到事件，兼容 Mouse Fix 等改写工具）
    func scrollList(by delta: CGFloat) {
        listScroller.scroll(by: delta)
    }

    func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        rowViewsPerScreen = []
        arrowsPerScreen = []
        iconSlotsPerScreen = []
        badgeOverlaysPerScreen = []
        listFramesPerScreen = []
        reusableSlotsPerScreen = []
        apps = []
        currentWindows = []
        badges = []
        onPickApp = nil
        onPickWindow = nil
        onHoverWindow = nil
        onScrollApp = nil
        onCancel = nil
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

    /// 容器承载内容与滚轮响应；背景材质层作为容器内的独立子视图（先加背景再加内容），
    /// 材质装配统一在 Theme，本处只给圆角尺寸（图标行与下拉列表圆角不同，故参数化）
    private func makeContainer(width: CGFloat, height: CGFloat,
                              cornerRadius: CGFloat = SwitcherMetrics.cornerRadius) -> ScrollContainerView {
        let container = ScrollContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        Theme.installBackground(on: container, cornerRadius: cornerRadius)
        return container
    }

    private func apply(_ background: NSView, to panel: NonKeyPanel, x: CGFloat, topY: CGFloat) {
        // setContentView 会把视图 resize 到窗口当前内容尺寸（初始为 zero），
        // 因此必须先保存目标尺寸，替换后再由 setContentSize 恢复
        let size = background.frame.size
        panel.contentView = background
        panel.setContentSize(size)
        panel.setFrameOrigin(CGPoint(x: x, y: topY - size.height))
        // contentView 替换后装 hover 探测层：鼠标进入该屏面板即转 key（玻璃聚焦跟随）
        panel.installHoverCatcher()
    }

    /// union 布局：把屏幕坐标矩形换算成 root 视图内的相对坐标
    private func relativeFrame(_ frame: NSRect, in union: NSRect) -> NSRect {
        NSRect(x: frame.minX - union.minX, y: frame.minY - union.minY,
               width: frame.width, height: frame.height)
    }

    private func render() {
        guard !panels.isEmpty, let hoverGate else { return }

        let total = currentWindows.count
        let shownCount = min(SwitcherMetrics.maxListRows, total)
        let clipHeight = CGFloat(shownCount) * SwitcherMetrics.rowHeight
        let contentHeight = CGFloat(total) * SwitcherMetrics.rowHeight

        var allRows: [[WindowRowView]] = []
        var scrollContents: [NSView] = []
        var allArrows: [(up: NSImageView, down: NSImageView)] = []
        var allSlots: [[IconSlotView]] = []
        var allBadgeOverlays: [NSView] = []
        var allListFrames: [NSRect] = []

        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            guard screenIndex < panels.count else { continue }
            let panel = panels[screenIndex]

            let cachedSlots = reusableSlotsPerScreen.indices.contains(screenIndex)
                ? reusableSlotsPerScreen[screenIndex] : nil
            let icon = layoutIconPanel(on: screen, hoverGate: hoverGate, cachedSlots: cachedSlots)

            // 窗口列表挂在图标行下方（名称已并入托盘内，不再是独立组件）
            let list = layoutListPanel(on: screen,
                                       topY: icon.frame.minY - SwitcherMetrics.panelGap,
                                       highlightedCenter: icon.highlightedCenter,
                                       clipHeight: clipHeight, contentHeight: contentHeight,
                                       hoverGate: hoverGate)

            // 图标行与列表合并进单窗口：union 矩形容纳两者，子容器按相对坐标摆放，
            // 间隙保持透明（与原双面板间的屏幕缝隙视觉等价）
            var union = icon.frame
            if let list { union = union.union(list.frame) }

            let root = NSView(frame: NSRect(x: 0, y: 0, width: union.width, height: union.height))
            icon.container.frame = relativeFrame(icon.frame, in: union)
            root.addSubview(icon.container)

            if let list {
                list.container.frame = relativeFrame(list.frame, in: union)
                root.addSubview(list.container)
                allRows.append(list.rows)
                scrollContents.append(list.scrollContent)
                allArrows.append(list.arrows)
                allListFrames.append(list.frame)
            }

            // 透明间隙点击层：union 矩形内、各容器之外的区域视觉透明，但点击
            // 会命中本 app 窗口而不触发「面板外点击取消」（global monitor 只收
            // app 外事件），垫底承接这些区域的点击 → 取消面板，语义等同面板外
            let cancelCatcher = TransparentClickCatcher(frame: root.bounds)
            cancelCatcher.autoresizingMask = [.width, .height]
            cancelCatcher.onClick = { [weak self] in self?.onCancel?() }
            // 列表两侧透明间隙落在此层：滚动这些区域切换应用（等同滚动图标行），不滚列表
            cancelCatcher.onScrollStep = { [weak self] in self?.onScrollApp?($0) }
            root.addSubview(cancelCatcher, positioned: .below, relativeTo: icon.container)
            allSlots.append(icon.slots)
            allBadgeOverlays.append(icon.badgeOverlay)

            // union 顶部恒为图标行顶：窗口向下生长，图标行屏幕位置恒定
            // （原「列表高度变化不影响主面板位置」的约束保持成立）
            apply(root, to: panel, x: union.minX, topY: union.maxY)
        }

        rowViewsPerScreen = allRows
        arrowsPerScreen = allArrows
        iconSlotsPerScreen = allSlots
        reusableSlotsPerScreen = allSlots
        badgeOverlaysPerScreen = allBadgeOverlays
        listFramesPerScreen = allListFrames
        listScroller.onOffsetChanged = { [weak self] in self?.updateScrollArrows() }
        listScroller.attach(contents: scrollContents,
                            contentHeight: contentHeight, clipHeight: clipHeight)
        updateScrollArrows()
    }

    /// 布局图标行（不落窗口）：返回容器视图、屏幕坐标矩形、槽位视图、角标高层与高亮图标中心横坐标。
    /// cachedSlots 非空则复用已有槽位视图（切换应用不重建图标视图，避免重图标重绘闪烁、也更快）
    private func layoutIconPanel(on screen: NSScreen, hoverGate: MouseHoverGate,
                                 cachedSlots: [IconSlotView]?)
        -> (container: ScrollContainerView, frame: NSRect,
            slots: [IconSlotView], badgeOverlay: NSView, highlightedCenter: CGFloat) {
        let visibleFrame = screen.visibleFrame

        // 单行布局：图标大小随应用数量缩放；达到上限后不再放大，
        // 面板宽度始终紧贴图标总宽（不设尺寸下限，应用极多时面板也不会超出屏幕）
        let count = max(CGFloat(apps.count), 1)
        let availableWidth = visibleFrame.width - SwitcherMetrics.panelSideMargin * 2
        let slot = min(SwitcherMetrics.iconSizeMax,
                       (availableWidth - SwitcherMetrics.iconGap * (count - 1)) / count)

        let iconPanelWidth = slot * count + SwitcherMetrics.iconGap * (count - 1)
            + SwitcherMetrics.iconInset * 2
        // 图标垂直居中于托盘：下方留白（间距 + 文字 + 底部留白）与顶部留白相等，
        // 图标正中因此对齐托盘正中；底部留白取小值使托盘尽量紧凑
        let nameHeight = nameTextHeight()
        let bottomPad = SwitcherMetrics.nameGap + nameHeight + SwitcherMetrics.nameBottomInset
        let iconPanelHeight = slot + bottomPad * 2

        let background = makeContainer(width: iconPanelWidth, height: iconPanelHeight)
        background.onScrollStep = { [weak self] in self?.onScrollApp?($0) }

        // 图标底边距托盘底 = bottomPad，与顶部留白相等 → 图标居中
        let iconY = bottomPad

        // 复用已有槽位（切换应用时不重建，只挪到新容器并更新高亮）；首次或应用数变化才新建
        let slots: [IconSlotView]
        if let cachedSlots, cachedSlots.count == apps.count {
            slots = cachedSlots
            for (index, slotView) in slots.enumerated() {
                slotView.frame = NSRect(x: SwitcherMetrics.iconInset + CGFloat(index) * (slot + SwitcherMetrics.iconGap),
                                        y: iconY, width: slot, height: slot)
                slotView.setSelected(index == appIndex)
                background.addSubview(slotView)
            }
        } else {
            var built: [IconSlotView] = []
            for (index, app) in apps.enumerated() {
                let slotView = IconSlotView(index: index, icon: app.icon,
                                            iconSize: slot, slotSize: slot,
                                            hoverGate: hoverGate,
                                            onHover: { [weak self] in self?.onHoverApp?($0) },
                                            onClick: { [weak self] in self?.onPickApp?($0) })
                slotView.frame = NSRect(x: SwitcherMetrics.iconInset + CGFloat(index) * (slot + SwitcherMetrics.iconGap),
                                        y: iconY,
                                        width: slot, height: slot)
                slotView.setSelected(index == appIndex)
                background.addSubview(slotView)
                built.append(slotView)
            }
            slots = built
        }

        // 只有选中图标下方显示应用名：托盘内、图标下方的文字区，横向居中于选中图标
        if apps.indices.contains(appIndex) {
            let iconCenterX = SwitcherMetrics.iconInset
                + CGFloat(appIndex) * (slot + SwitcherMetrics.iconGap) + slot / 2
            addNameLabel(apps[appIndex].name, to: background,
                         centerX: iconCenterX, panelWidth: iconPanelWidth,
                         y: SwitcherMetrics.nameBottomInset, height: nameHeight)
        }

        // 角标高层：叠在所有图标之上（在槽位全部加入后再加，故 z 序最高），
        // 图标特别多、后一个图标压住前一个角标的情况下仍可见
        let badgeOverlay = BadgeOverlayView(frame: background.bounds)
        badgeOverlay.autoresizingMask = [.width, .height]
        background.addSubview(badgeOverlay)
        placeBadges(on: badgeOverlay, slots: slots)

        // 图标面板自身垂直居中于该屏且位置固定
        let iconPanelX = visibleFrame.midX - iconPanelWidth / 2
        let iconPanelTop = visibleFrame.midY + iconPanelHeight / 2

        let highlightedCenter = iconPanelX + SwitcherMetrics.iconInset
            + CGFloat(appIndex) * (slot + SwitcherMetrics.iconGap) + slot / 2

        let frame = NSRect(x: iconPanelX, y: iconPanelTop - iconPanelHeight,
                           width: iconPanelWidth, height: iconPanelHeight)
        return (background, frame, slots, badgeOverlay, highlightedCenter)
    }

    /// 把各槽位的角标画到独立高层：位置沿用槽位内锚点、转成 overlay 坐标。
    /// overlay 叠在所有图标之上，角标因此不会被相邻图标遮挡
    private func placeBadges(on overlay: NSView, slots: [IconSlotView]) {
        overlay.subviews.forEach { $0.removeFromSuperview() }
        for (index, slot) in slots.enumerated() {
            guard badges.indices.contains(index),
                  let badge = slot.makeBadge(text: badges[index]) else { continue }
            badge.setFrameOrigin(overlay.convert(badge.frame.origin, from: slot))
            overlay.addSubview(badge)
        }
    }

    /// 名称文字区高度（单行行高，与具体名称无关）：托盘据此预留固定底部空间
    private func nameTextHeight() -> CGFloat {
        ceil(("Ag国" as NSString).size(withAttributes: [.font: SwitcherMetrics.nameFont]).height)
    }

    /// 在托盘内图标下方放置应用名：横向居中于图标，夹在托盘内边距内，
    /// 文字全宽超过可用宽度时中间截断（不越出托盘、不被圆角裁切）
    private func addNameLabel(_ name: String, to container: NSView,
                              centerX: CGFloat, panelWidth: CGFloat,
                              y: CGFloat, height: CGFloat) {
        guard !name.isEmpty else { return }
        let label = NSTextField(labelWithString: name)
        label.font = SwitcherMetrics.nameFont
        label.textColor = .labelColor
        label.alignment = .center
        label.backgroundColor = .clear
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        // sizeToFit 让字段自算贴合文字的宽度（含单元格内部留白），避免手算误差导致末字截断
        label.sizeToFit()

        let innerWidth = panelWidth - SwitcherMetrics.iconInset * 2
        let width = min(ceil(label.frame.width), innerWidth)
        var x = centerX - width / 2
        x = max(SwitcherMetrics.iconInset, min(x, panelWidth - SwitcherMetrics.iconInset - width))

        label.frame = NSRect(x: x, y: y, width: width, height: height)
        container.addSubview(label)
    }

    /// 布局窗口列表（不落窗口）：顶边挂在 topY 处（图标行下方），
    /// 无窗口返回 nil（列表不显示）
    private func layoutListPanel(on screen: NSScreen, topY: CGFloat,
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
        // 列表内容宽 listWidth，面板宽加两侧边距；行占满面板宽（两侧边距可点击），
        // 高亮块由行内 contentInset 内缩，视觉宽度仍为 listWidth
        let panelWidth = listWidth + SwitcherMetrics.edgeInset * 2
        let background = makeContainer(width: panelWidth, height: height,
                                       cornerRadius: SwitcherMetrics.listCornerRadius)
        background.onScrollRaw = { [weak self] in self?.listScroller.scroll(by: $0) }

        // 裁剪视口 + 承载全部行的内容视图：滚动只平移内容视图，不重建任何行
        let clip = NSView(frame: NSRect(x: 0, y: SwitcherMetrics.edgeInset,
                                        width: panelWidth, height: clipHeight))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        background.addSubview(clip)

        let content = NSView(frame: NSRect(x: 0, y: clipHeight - contentHeight,
                                           width: panelWidth, height: contentHeight))
        var rows: [WindowRowView] = []
        for (index, item) in currentWindows.enumerated() {
            let row = WindowRowView(index: index, icon: appIcon, title: item.title,
                                    width: panelWidth,
                                    contentInset: SwitcherMetrics.edgeInset,
                                    hoverGate: hoverGate,
                                    onHover: { [weak self] in self?.onHoverWindow?($0) },
                                    onClick: { [weak self] in self?.onPickWindow?($0) })
            row.frame = NSRect(x: 0,
                               y: CGFloat(total - 1 - index) * SwitcherMetrics.rowHeight,
                               width: panelWidth,
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

        // 顶边对齐传入锚点，越出屏幕时横向夹回该屏可见范围
        let visibleFrame = screen.visibleFrame
        var x = highlightedCenter - panelWidth / 2
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - panelWidth))
        let frame = NSRect(x: x,
                           y: topY - height,
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

/// 透明间隙点击层：垫在图标行/列表容器之下，承接 union 窗口内透明区域的点击，
/// 视觉上这些区域不属于面板，点击语义等同面板外 → 取消。
/// 滚轮不驱动列表（列表只在悬停其上时滚动），而是像图标行一样切换应用：
/// 列表两侧的空白间隙落在本层，滚动这里前后切 app
private final class TransparentClickCatcher: NSView {
    var onClick: (() -> Void)?
    var onScrollStep: ((Int) -> Void)?

    // 触控板/滚轮是连续事件流，累积到阈值才走一步，避免一次滑动跳过多个应用（与 ScrollContainerView 同）
    private var accumulatedDelta: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        // pixelScrollDelta 已把普通鼠标的行增量换算成像素，与触摸板手感统一
        accumulatedDelta += event.pixelScrollDelta
        guard abs(accumulatedDelta) >= 12 else { return }
        let step = accumulatedDelta > 0 ? 1 : -1
        accumulatedDelta = 0
        onScrollStep?(step)
    }
}

/// 角标高层：只承载角标、叠在图标之上；hitTest 透传，绝不拦截图标的点击与 hover
private final class BadgeOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class IconSlotView: NSView {

    private let index: Int
    private let hoverGate: MouseHoverGate
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void
    private let iconView: NSImageView
    // 选中高亮底色层：相对槽位内缩，圆角与图标圆角一致
    private let highlightLayer = CALayer()
    // 槽位边长（图标随应用数量缩放），角标尺寸随它等比缩放
    private let slotSize: CGFloat
    // 高亮相对槽位四周内缩的比例（缩小高亮范围，贴近图标可见方块）
    private static let highlightInset: CGFloat = 0.05

    init(index: Int, icon: NSImage?, iconSize: CGFloat, slotSize: CGFloat,
         hoverGate: MouseHoverGate,
         onHover: @escaping (Int) -> Void,
         onClick: @escaping (Int) -> Void) {
        self.index = index
        self.slotSize = slotSize
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
        // 关闭隐式动画：切换重建时高亮层直接就位，不做淡入/位移动画
        highlightLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(),
                                  "position": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(highlightLayer)
        addSubview(iconView)
    }

    override func layout() {
        super.layout()
        // 高亮内缩到贴近图标可见方块；圆角与图标圆角一致（≈边长 22.37%）
        let inset = bounds.width * Self.highlightInset
        highlightLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        highlightLayer.cornerRadius = highlightLayer.frame.width * 0.2237
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        // 选中样式为透明稍暗的底色（玻璃上的暗色半透明块，深浅外观下都是「压暗」），
        // 画在内缩的高亮层上（范围小于槽位，贴近图标）
        highlightLayer.backgroundColor = selected
            ? NSColor.black.withAlphaComponent(0.2).cgColor
            : nil
    }

    /// 生成定位好的角标（本视图坐标系）；text 为空或 frame 未就绪时返回 nil。
    /// 角标不挂在本视图，改由上层画到独立高层，避免图标特别多时被相邻图标遮挡
    func makeBadge(text: String?) -> BadgeView? {
        guard let text, !text.isEmpty, frame.width > 0 else { return nil }

        let badge = BadgeView(text: text, iconSize: slotSize)
        // 内收骑角：badge 中心压在图案右上角偏左下 1/4 处，只外突 1/4
        // （整半骑角视觉上太飘，见实测反馈）
        let content = iconContentRect
        badge.frame.origin = NSPoint(x: content.maxX - badge.frame.width * 0.75,
                                     y: content.maxY - badge.frame.height * 0.75)
        return badge
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

/// Dock 同款未读角标：红底白字胶囊，宽度随文字自适应（"1" 是圆点、"99+" 加宽），
/// 高度与字号随图标槽位等比缩放（基准：154 槽位 ≈ 24pt 胶囊），夹 12–24pt 保可读
private final class BadgeView: NSView {

    init(text: String, iconSize: CGFloat) {
        // 全套尺寸按胶囊高度等比推导；基准 154 槽位 ≈ 48pt（约为图标的 1/3）
        let height = min(max(iconSize * 48 / 154, 24), 48)
        let font = NSFont.systemFont(ofSize: height * 2 / 3, weight: .semibold)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width

        super.init(frame: NSRect(x: 0, y: 0,
                                 width: max(height, textWidth + height * 7 / 12),
                                 height: height))

        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = height / 2

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        let labelHeight = height * 19 / 24
        label.frame = NSRect(x: 0, y: (height - labelHeight) / 2,
                             width: bounds.width, height: labelHeight)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
