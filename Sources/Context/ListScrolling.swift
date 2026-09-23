import AppKit

/// 窗口列表的连续滚动控制器：管理 clip/content 结构的视口偏移，
/// 滚轮增量直接映射为像素偏移，不重建任何视图。
/// 支持多屏（每屏一份内容视图），滚动时所有屏同步平移。
final class ListScrollController {

    /// 偏移变化后回调（面板据此更新箭头指示）
    var onOffsetChanged: (() -> Void)?

    let rowHeight: CGFloat

    private var contentViews: [NSView] = []
    private var contentHeight: CGFloat = 0
    private var clipHeight: CGFloat = 0
    private(set) var offset: CGFloat = 0

    init(rowHeight: CGFloat) {
        self.rowHeight = rowHeight
    }

    var maxScroll: CGFloat { max(0, contentHeight - clipHeight) }
    var hasMoreAbove: Bool { offset > 0.5 }
    var hasMoreBelow: Bool { maxScroll - offset > 0.5 }

    func attach(contents: [NSView], contentHeight: CGFloat, clipHeight: CGFloat) {
        self.contentViews = contents
        self.contentHeight = contentHeight
        self.clipHeight = clipHeight
        offset = 0
    }

    /// 滚轮驱动：系统归一化 delta 的正方向与期望的视口移动方向相反，取负
    func scroll(by delta: CGFloat) {
        guard maxScroll > 0 else { return }
        setOffset(offset - delta)
    }

    /// 选中项保持在可视区内，出界时视口直接对齐（无动画，优先性能）
    func ensureVisible(index: Int, total: Int) {
        guard maxScroll > 0, total > 0 else { return }

        let rowY = CGFloat(total - 1 - index) * rowHeight
        let rowTop = rowY + rowHeight
        let visibleBottom = contentHeight - clipHeight - offset
        let visibleTop = contentHeight - offset

        var target = offset
        if rowTop > visibleTop {
            target = contentHeight - rowTop
        } else if rowY < visibleBottom {
            target = contentHeight - clipHeight - rowY
        }
        if target != offset {
            setOffset(target)
        }
    }

    private func setOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), maxScroll)
        guard clamped != offset, !contentViews.isEmpty else { return }

        offset = clamped
        let y = clipHeight - contentHeight + clamped
        contentViews.forEach { $0.setFrameOrigin(CGPoint(x: 0, y: y)) }
        onOffsetChanged?()
    }
}

extension NSEvent {

    /// 普通鼠标滚轮一格的等效像素位移：取一个窗口列表行高，
    /// 使滚轮一格正好滚过一行（步进路径则一格切一个应用）
    private static let wheelLineStep: CGFloat = 34

    /// 滚轮增量归一化为像素：触摸板是精确设备、本就给像素；普通鼠标只给「行」增量
    /// （实测一格 scrollingDeltaY = ±1），直接当像素用会几乎不动——必须先乘回行高
    var pixelScrollDelta: CGFloat {
        let raw = abs(scrollingDeltaY) >= abs(scrollingDeltaX)
            ? scrollingDeltaY
            : scrollingDeltaX
        return hasPreciseScrollingDeltas ? raw : raw * Self.wheelLineStep
    }
}

/// 面板容器：承载滚轮响应；毛玻璃背景是它的子层，透明度独立于内容调节
final class ScrollContainerView: NSView {

    /// 阈值步进（应用切换等离散语义）
    var onScrollStep: ((Int) -> Void)?
    /// 原始增量直通（列表连续滚动），设置后优先于 onScrollStep
    var onScrollRaw: ((CGFloat) -> Void)?

    // 触控板滚动是连续事件流，累积到阈值才移动一步，避免一次滑动跳过多个应用
    private var accumulatedDelta: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        let delta = event.pixelScrollDelta

        if let onScrollRaw {
            onScrollRaw(delta)
            return
        }

        accumulatedDelta += delta
        if abs(accumulatedDelta) >= 12 {
            let step = accumulatedDelta > 0 ? 1 : -1
            accumulatedDelta = 0
            onScrollStep?(step)
        }
    }
}

extension NSImageView {

    /// 列表上下端「还有更多」的箭头指示（labelColor + 加粗，保证可见性）
    static func scrollIndicator(symbol: String, x: CGFloat, y: CGFloat) -> NSImageView {
        let arrow = NSImageView(frame: NSRect(x: x, y: y, width: 12, height: 12))
        arrow.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        arrow.contentTintColor = .labelColor
        arrow.imageScaling = .scaleProportionallyUpOrDown
        return arrow
    }
}
