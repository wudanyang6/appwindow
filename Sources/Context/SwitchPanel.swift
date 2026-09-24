import AppKit

// 文件级布局常量
private enum PanelMetrics {
    static let width: CGFloat = 520
    static let rowHeight: CGFloat = 34
    static let edgeInset: CGFloat = 8
    // 托盘圆角与行高亮圆角同心：高亮半径 8 + 高亮距托盘边 edgeInset 8 = 16，
    // 使托盘圆角与高亮圆角平行等距，视觉一致
    static let cornerRadius: CGFloat = 16
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
    /// onHover 在鼠标悬停行时回调（面板内部已同步视觉高亮），调用方负责同步自己的光标状态。
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

        var allRows: [[WindowRowView]] = []
        var scrollContents: [NSView] = []
        var allArrows: [(up: NSImageView, down: NSImageView)] = []

        for screen in NSScreen.screens {
            let panel = NonKeyPanel(contentRect: .zero,
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered,
                                    defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("switch-\(panels.count)")
            configure(panel)

            let (_, rows, scrollContent, arrows) = buildScreenContent(
                screen: screen, panel: panel, items: items, appIcon: appIcon,
                clipHeight: clipHeight, contentHeight: contentHeight,
                hoverGate: hoverGate, onHover: onHover
            )

            panels.append(panel)
            allRows.append(rows)
            scrollContents.append(scrollContent)
            allArrows.append(arrows)
        }

        rowViewsPerScreen = allRows
        arrowsPerScreen = allArrows
        listScroller.onOffsetChanged = { [weak self] in self?.updateScrollArrows() }
        listScroller.attach(contents: scrollContents,
                            contentHeight: contentHeight, clipHeight: clipHeight)
        updateScrollArrows()

        panels.forEach { $0.orderFrontRegardless() }
        // 首屏面板成 key，其他屏由 hover 激活（单 key 窗口模型，同 AppSwitcherPanel）
        if let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            DiagLog.log("panel", "switch makeKey: isKeyWindow=\(first.isKeyWindow) appActive=\(NSApp.isActive)")
        }
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

    /// 供全局滚轮驱动（窗口模式滚轮始终滚列表）：由 EventTapManager 调用
    func scrollList(by delta: CGFloat) {
        listScroller.scroll(by: delta)
    }

    func dismiss() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        rowViewsPerScreen = []
        arrowsPerScreen = []
        items = []
        onPick = nil
        NonKeyPanel.forceCloseVisible(prefix: "switch-")
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
        // close() 兜底清扫幽灵面板时，ARC 下必须关闭「关闭即释放」，否则清空引用会二次释放
        panel.isReleasedWhenClosed = false
    }

    /// 构建单个屏幕的完整面板内容；返回滚动用的内容视图与箭头供跨屏同步
    private func buildScreenContent(screen: NSScreen, panel: NonKeyPanel,
                                    items: [WindowItem], appIcon: NSImage?,
                                    clipHeight: CGFloat, contentHeight: CGFloat,
                                    hoverGate: MouseHoverGate,
                                    onHover: @escaping (Int) -> Void)
        -> (content: NSView, rows: [WindowRowView], scrollContent: NSView,
            arrows: (up: NSImageView, down: NSImageView)) {

        let total = items.count
        let height = clipHeight + PanelMetrics.edgeInset * 2

        let background = ScrollContainerView(frame: NSRect(x: 0, y: 0,
                                                           width: PanelMetrics.width, height: height))
        // 材质与 cmd+tab 图标行同款，装配逻辑统一在 Theme
        Theme.installBackground(on: background, cornerRadius: PanelMetrics.cornerRadius)
        background.onScrollRaw = { [weak self] in self?.listScroller.scroll(by: $0) }

        // 裁剪视口 + 承载全部行的内容视图：滚动只平移内容视图，不重建任何行。
        // 视口全宽：行占满面板宽（两侧边距可点击），高亮块由行内 contentInset 内缩
        let clip = NSView(frame: NSRect(x: 0, y: PanelMetrics.edgeInset,
                                        width: PanelMetrics.width, height: clipHeight))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        background.addSubview(clip)

        let content = NSView(frame: NSRect(x: 0, y: clipHeight - contentHeight,
                                           width: PanelMetrics.width, height: contentHeight))
        var rows: [WindowRowView] = []
        for (index, item) in items.enumerated() {
            let row = WindowRowView(index: index, icon: appIcon, title: item.title,
                                    width: PanelMetrics.width,
                                    contentInset: PanelMetrics.edgeInset,
                                    hoverGate: hoverGate,
                                    onHover: { [weak self] index in
                                        self?.select(index: index)
                                        onHover(index)
                                    },
                                    onClick: { [weak self] in self?.pickRow(at: $0) })
            row.frame = NSRect(x: 0,
                               y: CGFloat(total - 1 - index) * PanelMetrics.rowHeight,
                               width: PanelMetrics.width,
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

        // setContentView 会把视图 resize 到窗口当前内容尺寸（初始为 zero），
        // 先保存目标尺寸，替换后再由 setContentSize 恢复
        let size = background.frame.size
        panel.contentView = background
        panel.setContentSize(size)
        // contentView 替换后装 hover 探测层：鼠标进入该屏面板即转 key（玻璃聚焦跟随）
        panel.installHoverCatcher()

        // 屏幕正中央
        let frame = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2,
                                     y: frame.midY - size.height / 2))

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

/// nonactivating 面板：可成为 key window（驱动玻璃聚焦样式）但绝不激活 App、
/// 不改变当前 active app；键盘事件仍由 EventTapManager 在事件 tap 层拦截驱动
final class NonKeyPanel: NSPanel {

    override var canBecomeKey: Bool { true }

    /// 强制关闭 app 内所有 identifier 以 prefix 打头、且仍可见的本类面板。
    /// 覆盖两类残留：本次会话正在收起、但 orderOut 未即时生效的面板；
    /// 以及往次会话交接时 orderOut 失效、又被 dismiss 清空引用后无主的「幽灵」。
    /// dismiss 里同步调用：此刻本会话面板已 orderOut（isVisible=false，不误伤），
    /// 只有真正滞留在屏的才被 close 摘除，因此不会累积；show 先 dismiss 再建新面板，
    /// 新面板在本方法返回后才创建，也不会被扫到。
    static func forceCloseVisible(prefix: String) {
        let ghosts = NSApp.windows.compactMap { $0 as? NonKeyPanel }
            .filter { $0.identifier?.rawValue.hasPrefix(prefix) == true && $0.isVisible }
        guard !ghosts.isEmpty else { return }
        ghosts.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        DiagLog.log("dismiss", "forceCloseVisible prefix=\(prefix) swept=\(ghosts.count)")
    }

    // key 状态流转打点：排查玻璃聚焦样式不生效时区分「没成为 key」与「成了 key 但玻璃不认」
    override func becomeKey() {
        super.becomeKey()
        DiagLog.log("panel", "becomeKey id=\(identifier?.rawValue ?? "?") appActive=\(NSApp.isActive)")
    }

    override func resignKey() {
        super.resignKey()
        DiagLog.log("panel", "resignKey id=\(identifier?.rawValue ?? "?") appActive=\(NSApp.isActive)")
    }

    /// 鼠标进入该屏面板区域时把面板转正为 key：多屏各一份面板，仅主屏面板
    /// 在 show 时 makeKey，其他屏玻璃呈失焦态；进入即转 key，玻璃聚焦渲染跟随。
    /// 单 key 窗口模型下转正必然抢走前一屏的 key，直接切换（过渡补偿方案
    /// 已多轮实测被否，不再叠加）
    func installHoverCatcher() {
        let catcher = PanelHoverCatcher(frame: contentView?.bounds ?? .zero)
        catcher.autoresizingMask = [.width, .height]
        catcher.onEnter = { [weak self] in self?.makeKeyAndOrderFront(nil) }
        contentView?.addSubview(catcher)
    }
}

/// 全窗 hover 探测层：hitTest 穿透（点击/悬停/滚轮仍由图标与行视图处理），
/// 仅承载 trackingArea，鼠标进入所在屏面板时回调
final class PanelHoverCatcher: NSView {
    var onEnter: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class WindowRowView: NSView {

    private let index: Int
    private let titleLabel = NSTextField(labelWithString: "")
    // 高亮块独立子层：行本体占满面板宽（两侧边距同样可点击，原生菜单行为），
    // 视觉宽度由高亮块内缩 contentInset 保持
    private let highlightLayer = CALayer()
    private let contentInset: CGFloat
    private let hoverGate: MouseHoverGate
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void

    init(index: Int, icon: NSImage?, title: String, width: CGFloat,
         contentInset: CGFloat,
         hoverGate: MouseHoverGate,
         onHover: @escaping (Int) -> Void, onClick: @escaping (Int) -> Void) {
        self.index = index
        self.contentInset = contentInset
        self.hoverGate = hoverGate
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)

        wantsLayer = true
        highlightLayer.cornerRadius = 8
        layer?.addSublayer(highlightLayer)

        let iconView = NSImageView(frame: NSRect(x: contentInset + 8, y: 8, width: 18, height: 18))
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
        titleLabel.frame = NSRect(x: contentInset + 34, y: 9,
                                  width: width - contentInset * 2 - 42, height: 18)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlighted(_ highlighted: Bool) {
        // 高亮为透明稍暗的底色（玻璃上的暗色半透明块），文字保持 labelColor
        // 随系统外观自适应，不再反白
        highlightLayer.backgroundColor = highlighted
            ? NSColor.black.withAlphaComponent(0.2).cgColor
            : nil
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: contentInset + 34, y: 9,
                                  width: bounds.width - contentInset * 2 - 42, height: 18)
        highlightLayer.frame = bounds.insetBy(dx: contentInset, dy: 0)
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
