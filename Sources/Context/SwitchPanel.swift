import AppKit

// 文件级布局常量
private enum PanelMetrics {
    static let width: CGFloat = 520
    static let rowHeight: CGFloat = 34
    static let edgeInset: CGFloat = 8
    // 与 cmd+tab 面板统一圆角
    static let cornerRadius: CGFloat = 26
    // 面板高度目标：屏幕可视高度的 70%
    static let heightRatio: CGFloat = 0.70

    /// 按屏幕高度推导可视行数（多屏时取最小屏，保证各屏显示一致），超出部分滚动显示
    static func maxListRows() -> Int {
        let screens = NSScreen.screens
        let minHeight = screens.map(\.visibleFrame.height).min() ?? 900
        let available = minHeight * heightRatio - edgeInset * 2
        return max(4, Int(available / rowHeight))
    }
}

/// cmd+` 窗口选择面板：非激活、不抢键盘焦点，键盘交互由 EventTapManager 驱动。
/// 鼠标支持 hover 高亮、点击直选与滚轮连续滚动；**每个屏幕各显示一份**，状态跨屏同步。
final class SwitchPanel {

    private var panels: [NonKeyPanel] = []
    // 每屏一套行视图（index 与窗口索引一致），高亮切换遍历所有屏
    private var rowViewsPerScreen: [[WindowRowView]] = []
    private var items: [WindowItem] = []
    private var selectedIndex = 0
    private var onPick: ((Int) -> Void)?

    private let listScroller = ListScrollController(rowHeight: PanelMetrics.rowHeight)
    private var arrowsPerScreen: [(up: NSImageView, down: NSImageView)] = []

    /// 显示面板并高亮 initialSelected 对应的行。
    /// onHover 在鼠标悬停行时回调（面板内部已同步视觉高亮），调用方负责同步提交状态。
    func show(items: [WindowItem], appIcon: NSImage?,
              selected initialSelected: Int,
              onPick: @escaping (Int) -> Void,
              onHover: @escaping (Int) -> Void) {
        dismiss()

        self.items = items
        self.onPick = onPick
        selectedIndex = initialSelected

        let shownCount = min(PanelMetrics.maxListRows(), items.count)
        let clipHeight = CGFloat(shownCount) * PanelMetrics.rowHeight
        let contentHeight = CGFloat(items.count) * PanelMetrics.rowHeight
        let hoverGate = MouseHoverGate()

        // 跨屏单窗：液态玻璃的聚焦渲染跟随窗口 key 状态，而一个 app 只有一个
        // key window；每屏各开一窗时非 key 屏的玻璃会退化为失活样式，单窗共享聚焦态。
        // 窗口覆盖所有屏可视区域的联合矩形，空白区经 PanelRootView 穿透，不挡下层
        let screens = NSScreen.screens
        let bounds = screens.map(\.visibleFrame).reduce(screens[0].visibleFrame) { $0.union($1) }
        let root = PanelRootView(frame: NSRect(origin: .zero, size: bounds.size))

        var allRows: [[WindowRowView]] = []
        var scrollContents: [NSView] = []
        var allArrows: [(up: NSImageView, down: NSImageView)] = []

        for screen in screens {
            let (background, rows, scrollContent, arrows) = buildScreenContent(
                items: items, appIcon: appIcon,
                clipHeight: clipHeight, contentHeight: contentHeight,
                hoverGate: hoverGate, onHover: onHover
            )
            // 屏幕正中央（屏幕全局坐标）→ 窗口内相对坐标
            let size = background.frame.size
            let visible = screen.visibleFrame
            let center = NSRect(x: visible.midX - size.width / 2,
                                y: visible.midY - size.height / 2,
                                width: size.width, height: size.height)
            background.frame = center.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            root.addSubview(background)
            allRows.append(rows)
            scrollContents.append(scrollContent)
            allArrows.append(arrows)
        }

        let panel = NonKeyPanel(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("switch-0")
        configure(panel)
        panels = [panel]

        rowViewsPerScreen = allRows
        arrowsPerScreen = allArrows
        listScroller.onOffsetChanged = { [weak self] in self?.updateScrollArrows() }
        listScroller.attach(contents: scrollContents,
                            contentHeight: contentHeight, clipHeight: clipHeight)
        updateScrollArrows()

        panel.contentView = root
        panel.setContentSize(bounds.size)
        panel.setFrameOrigin(bounds.origin)
        panel.orderFrontRegardless()
        // 成 key 使玻璃呈聚焦样式（激活语义见 AppSwitcherPanel.show 的注释）
        panel.makeKeyAndOrderFront(nil)
        DiagLog.log("panel", "switch makeKey: isKeyWindow=\(panel.isKeyWindow) appActive=\(NSApp.isActive)")
    }

    func select(index: Int) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        for rows in rowViewsPerScreen {
            if rows.indices.contains(selectedIndex) { rows[selectedIndex].setHighlighted(false) }
            if rows.indices.contains(index) { rows[index].setHighlighted(true) }
        }
        selectedIndex = index
        listScroller.ensureVisible(index: index, total: items.count)
    }

    func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        rowViewsPerScreen = []
        arrowsPerScreen = []
        items = []
        onPick = nil
    }

    private func pickRow(at index: Int) {
        onPick?(index)
    }
}

// MARK: - 渲染与布局

private extension SwitchPanel {

    private func configure(_ panel: NSPanel) {
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 应用常驻后台，若响应 deactivate 收起会把面板立刻关掉
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
    }

    /// 构建单个屏幕的面板内容（原点 0,0，屏幕定位由调用方平移进跨屏单窗）；
    /// 返回滚动用的内容视图与箭头供跨屏同步
    private func buildScreenContent(items: [WindowItem], appIcon: NSImage?,
                                    clipHeight: CGFloat, contentHeight: CGFloat,
                                    hoverGate: MouseHoverGate,
                                    onHover: @escaping (Int) -> Void)
        -> (content: NSView, rows: [WindowRowView], scrollContent: NSView,
            arrows: (up: NSImageView, down: NSImageView)) {

        let total = items.count
        let height = clipHeight + PanelMetrics.edgeInset * 2
        let rowWidth = PanelMetrics.width - PanelMetrics.edgeInset * 2

        let background = ScrollContainerView(frame: NSRect(x: 0, y: 0,
                                                           width: PanelMetrics.width, height: height))
        background.wantsLayer = true
        background.layer?.cornerRadius = PanelMetrics.cornerRadius
        background.layer?.masksToBounds = true
        background.onScrollRaw = { [weak self] in self?.listScroller.scroll(by: $0) }

        // 背景层与 cmd+tab 图标行同款玻璃配置：毛玻璃打底提供模糊（alpha 控强度），
        // clear 液态玻璃质感层在上，黑 tint 统一亮度
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: background.bounds)
            glass.autoresizingMask = [.width, .height]
            glass.style = .clear
            glass.cornerRadius = PanelMetrics.cornerRadius
            glass.tintColor = NSColor.black.withAlphaComponent(0.15)
            let blur = NSVisualEffectView(frame: background.bounds)
            blur.autoresizingMask = [.width, .height]
            blur.material = .menu
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.alphaValue = 0.75
            background.addSubview(blur, positioned: .below, relativeTo: glass)
            background.addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: background.bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = PanelMetrics.cornerRadius
            effect.alphaValue = Theme.backgroundAlpha
            background.addSubview(effect)
        }

        // 裁剪视口 + 承载全部行的内容视图：滚动只平移内容视图，不重建任何行
        let clip = NSView(frame: NSRect(x: PanelMetrics.edgeInset, y: PanelMetrics.edgeInset,
                                        width: rowWidth, height: clipHeight))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        background.addSubview(clip)

        let content = NSView(frame: NSRect(x: 0, y: clipHeight - contentHeight,
                                           width: rowWidth, height: contentHeight))
        var rows: [WindowRowView] = []
        for (index, item) in items.enumerated() {
            let row = WindowRowView(index: index, icon: appIcon, title: item.title,
                                    width: rowWidth, hoverGate: hoverGate,
                                    onHover: { [weak self] index in
                                        self?.select(index: index)
                                        onHover(index)
                                    },
                                    onClick: { [weak self] in self?.pickRow(at: $0) })
            row.frame = NSRect(x: 0,
                               y: CGFloat(total - 1 - index) * PanelMetrics.rowHeight,
                               width: rowWidth,
                               height: PanelMetrics.rowHeight)
            row.setHighlighted(index == selectedIndex)
            content.addSubview(row)
            rows.append(row)
        }
        clip.addSubview(content)

        let arrowX = PanelMetrics.width / 2 - 6
        let up = NSImageView.scrollIndicator(symbol: "chevron.up", x: arrowX, y: height - 13)
        let down = NSImageView.scrollIndicator(symbol: "chevron.down", x: arrowX, y: 1)
        background.addSubview(up)
        background.addSubview(down)

        return (background, rows, content, (up, down))
    }

    private func updateScrollArrows() {
        for arrows in arrowsPerScreen {
            arrows.up.isHidden = !listScroller.hasMoreAbove
            arrows.down.isHidden = !listScroller.hasMoreBelow
        }
    }
}

// MARK: - 共享子视图（AppSwitcherPanel 复用）

/// 跨屏单窗的根视图：命中自身（玻璃容器之外的空白区）返回 nil，
/// 鼠标事件穿透到下层窗口，避免大窗口挡住整片屏幕的交互
final class PanelRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// nonactivating 面板：可成为 key window（驱动玻璃聚焦样式）但绝不激活 App、
/// 不改变当前 active app；键盘事件仍由 EventTapManager 在事件 tap 层拦截驱动
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // key 状态流转打点：排查玻璃聚焦样式不生效时区分「没成为 key」与「成了 key 但玻璃不认」
    override func becomeKey() {
        super.becomeKey()
        DiagLog.log("panel", "becomeKey id=\(identifier?.rawValue ?? "?") appActive=\(NSApp.isActive)")
    }

    override func resignKey() {
        super.resignKey()
        DiagLog.log("panel", "resignKey id=\(identifier?.rawValue ?? "?") appActive=\(NSApp.isActive)")
    }
}

final class WindowRowView: NSView {

    private let index: Int
    private let titleLabel = NSTextField(labelWithString: "")
    private let hoverGate: MouseHoverGate
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void

    init(index: Int, icon: NSImage?, title: String, width: CGFloat,
         hoverGate: MouseHoverGate,
         onHover: @escaping (Int) -> Void, onClick: @escaping (Int) -> Void) {
        self.index = index
        self.hoverGate = hoverGate
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8

        let iconView = NSImageView(frame: NSRect(x: 8, y: 8, width: 18, height: 18))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.wraps = false
        titleLabel.cell?.truncatesLastVisibleLine = true
        // 手动 frame 布局不保证触发 layout()，初始宽度必须在此设置
        titleLabel.frame = NSRect(x: 34, y: 9, width: width - 42, height: 18)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : nil
        titleLabel.textColor = highlighted ? .white : .labelColor
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 34, y: 9, width: bounds.width - 42, height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        onClick(index)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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
}
