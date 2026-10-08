import AppKit

// 文件级布局常量：全部来自 Tuning（设置窗口可调），每次 show 读取 → 改配置下次显示生效
enum PanelMetrics {
    static var width: CGFloat { Tuning.panelWidth.value }
    static var rowHeight: CGFloat { Tuning.rowHeight.value }
    static var edgeInset: CGFloat { Tuning.edgeInset.value }
    static var cornerRadius: CGFloat { Tuning.listCornerRadius.value }
    // 默认值下托盘圆角与行高亮圆角同心（高亮半径 8 + 距托盘边 edgeInset 8 = 16）；
    // 两者现已可独立配置，该关系仅在默认值下成立
    // 面板高度目标：屏幕可视高度的一定比例
    static var heightRatio: CGFloat { Tuning.heightRatio.value }
    // 行标题字体：与 AppSwitcherPanel 共用同一配置来源
    static var listFont: NSFont { .systemFont(ofSize: Tuning.listFontSize.value) }

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

    private let listScroller = ListScrollController()
    private var arrowsPerScreen: [(up: NSImageView, down: NSImageView)] = []

    /// 显示面板并高亮 initialSelected 对应的行。
    /// onHover 在鼠标悬停行时回调（面板内部已同步视觉高亮），调用方负责同步自己的光标状态。
    func show(items: [WindowItem], appIcon: NSImage?,
              selected initialSelected: Int,
              onPick: @escaping (Int) -> Void,
              onHover: @escaping (Int) -> Void,
              makeKey: Bool = true) {
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
        listScroller.attach(contents: scrollContents, rowHeight: PanelMetrics.rowHeight,
                            total: items.count, shown: shownCount)
        updateScrollArrows()

        panels.forEach { $0.orderFrontRegardless() }
        // 首屏面板成 key，其他屏由 hover 激活（单 key 窗口模型，同 AppSwitcherPanel）；
        // 实时预览传 false：设置窗口保持 key，拖参数不被抢焦点
        if makeKey {
            if let first = panels.first {
                first.makeKeyAndOrderFront(nil)
                DiagLog.log("panel", "switch makeKey: isKeyWindow=\(first.isKeyWindow) appActive=\(NSApp.isActive)")
            }
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
        // 材质与 cmd+tab 图标行同款，装配逻辑统一在 Theme；内容装入玻璃的 contentView
        let themeBackground = Theme.installBackground(on: background, cornerRadius: PanelMetrics.cornerRadius)
        background.onScrollRaw = { [weak self] in self?.listScroller.scroll(by: $0) }

        // 裁剪视口 + 承载全部行的内容视图：滚动只平移内容视图，不重建任何行。
        // 视口全宽：行占满面板宽（两侧边距可点击），高亮块由行内 contentInset 内缩
        let clip = NSView(frame: NSRect(x: 0, y: PanelMetrics.edgeInset,
                                        width: PanelMetrics.width, height: clipHeight))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        themeBackground.contentHost.addSubview(clip)

        let content = NSView(frame: NSRect(x: 0, y: clipHeight - contentHeight,
                                           width: PanelMetrics.width, height: contentHeight))
        var rows: [WindowRowView] = []
        for (index, item) in items.enumerated() {
            let row = WindowRowView(index: index, icon: appIcon, title: item.title,
                                    width: PanelMetrics.width,
                                    contentInset: PanelMetrics.edgeInset,
                                    font: PanelMetrics.listFont,
                                    rowHeight: PanelMetrics.rowHeight,
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
        themeBackground.contentHost.addSubview(up)
        themeBackground.contentHost.addSubview(down)

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
    private let iconView = NSImageView()
    // 高亮块独立子层：行本体占满面板宽（两侧边距同样可点击，原生菜单行为），
    // 视觉宽度由高亮块内缩 contentInset 保持
    private let highlightLayer = CALayer()
    private let contentInset: CGFloat
    private let font: NSFont
    private let hoverGate: MouseHoverGate
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void

    init(index: Int, icon: NSImage?, title: String, width: CGFloat,
         contentInset: CGFloat, font: NSFont, rowHeight: CGFloat,
         hoverGate: MouseHoverGate,
         onHover: @escaping (Int) -> Void, onClick: @escaping (Int) -> Void) {
        self.index = index
        self.contentInset = contentInset
        self.font = font
        self.hoverGate = hoverGate
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)

        wantsLayer = true
        highlightLayer.cornerRadius = 8
        layer?.addSublayer(highlightLayer)

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = font
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.wraps = false
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)

        // 手动 frame 布局不保证触发 layout()，初始 frame 必须在此按预期行高设置
        applyLayout(width: width, height: rowHeight)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 行内布局：图标与标题垂直居中，随行高自适应。
    /// 默认 34pt 行高下与改造前逐像素一致（图标 (inset+8, 8, 18, 18)、标题 (inset+34, 9, w, 18)）
    private func applyLayout(width: CGFloat, height: CGFloat) {
        let iconSide = min(18, max(12, height - 16))
        let iconX = contentInset + 8
        iconView.frame = NSRect(x: iconX, y: (height - iconSide) / 2, width: iconSide, height: iconSide)

        // 文本在 cell 内相对 frame 顶边锚定：用至少 18 高的行盒 + 1pt 光学偏移复刻旧布局；
        // 行盒被行高与文字高度共同夹住，极端组合（大字号 + 矮行）也不越出行边界
        let titleHeight = ceil(font.ascender - font.descender + font.leading)
        let boxHeight = min(max(titleHeight, 18), height)
        let titleX = iconX + iconSide + 8
        let titleY = min((height - boxHeight) / 2 + 1, height - boxHeight)
        titleLabel.frame = NSRect(x: titleX,
                                  y: titleY,
                                  width: max(0, width - titleX - contentInset - 8),
                                  height: boxHeight)
        highlightLayer.frame = NSRect(x: contentInset, y: 0,
                                      width: max(0, width - contentInset * 2), height: height)
    }

    func setHighlighted(_ highlighted: Bool) {
        // 高亮为透明半透明块，颜色随外观取（浅色 = 黑 20%、暗色 = 白 18%，见 Theme）；
        // 文字保持 labelColor 随系统外观自适应，不再反白。
        // 视图未入窗时（首建渲染阶段）回退到应用级外观
        if highlighted {
            let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
            highlightLayer.backgroundColor = Theme.windowRowHighlightColor(for: appearance).cgColor
        } else {
            highlightLayer.backgroundColor = nil
        }
    }

    override func layout() {
        super.layout()
        applyLayout(width: bounds.width, height: bounds.height)
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
