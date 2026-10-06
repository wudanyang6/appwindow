import AppKit

/// 设置窗口内嵌的面板预览：用与真实面板相同的几何指标（SwitcherMetrics/PanelMetrics）
/// 与示例数据渲染，参数变化时由设置窗口调用 rebuild() 即时重建。
/// 固定缩放（不随内容自适应）——参数变化在预览里直接可见
final class PanelPreviewView: NSView {

    enum Mode {
        case appSwitcher
        case windowSwitcher
    }

    /// 固定缩放系数：内容按「真实尺寸 × scale」构建（不缩放字体以外的布局变换，
    /// 保证预览与真实面板的几何关系一致）
    static let scale: CGFloat = 0.5

    private let mode: Mode
    private let contentView = NSView()
    /// 内容自然尺寸（未缩放前；测试用）
    private(set) var contentSize: NSSize = .zero
    // 示例应用（名称 + 图标）：会话内取一次，避免每次重建都枚举进程
    private lazy var sampleApps: [(name: String, icon: NSImage?)] = {
        let apps = WindowListService.switcherApps().prefix(5)
        guard !apps.isEmpty else {
            let symbol = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            return (1...5).map { ("示例应用 \($0)", symbol) }
        }
        return apps.map { ($0.name, $0.icon) }
    }()

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(contentView)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 参数变化后重建内容（设置窗口在任意几何控件变化时调用）
    func rebuild() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        switch mode {
        case .appSwitcher:
            contentSize = buildAppSwitcherPreview()
        case .windowSwitcher:
            contentSize = buildWindowSwitcherPreview()
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentSize.height + 12)
    }

    override func layout() {
        super.layout()
        // 内容水平居中，垂直留 6pt
        contentView.frame = NSRect(
            x: max(0, (bounds.width - contentSize.width) / 2),
            y: 6,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private func s(_ value: CGFloat) -> CGFloat {
        value * Self.scale
    }

    private func scaledFont(_ font: NSFont) -> NSFont {
        .systemFont(ofSize: font.pointSize * Self.scale, weight: .medium)
    }

    // MARK: - Cmd+Tab 应用切换器预览

    private func buildAppSwitcherPreview() -> NSSize {
        let samples = sampleApps
        let count = CGFloat(samples.count)

        // 槽位公式用一块「足够宽」的虚拟屏，让图标最大/最小尺寸成为主导因素（与真实公式同源）
        let slot = s(SwitcherMetrics.iconSlotSize(count: samples.count, availableWidth: 5000))
        let gap = s(SwitcherMetrics.iconGap)
        let iconInset = s(SwitcherMetrics.iconInset)
        let nameFont = scaledFont(SwitcherMetrics.nameFont)
        let nameHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        let bottomPad = s(SwitcherMetrics.nameGap) + nameHeight + s(SwitcherMetrics.nameBottomInset)
        let rowWidth = slot * count + gap * (count - 1) + iconInset * 2
        let rowHeight = slot + bottomPad * 2

        let iconRow = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight))
        let iconRowHost = Theme.installBackground(
            on: iconRow, cornerRadius: s(SwitcherMetrics.cornerRadius)
        ).contentHost

        for (index, sample) in samples.enumerated() {
            let x = iconInset + CGFloat(index) * (slot + gap)
            if index == 0 {
                // 选中高亮：与真实面板同款（灰色玻璃胶囊：灰色填充 + 灰色描边）
                let highlight = NSView(frame: NSRect(x: x, y: bottomPad, width: slot, height: slot))
                highlight.wantsLayer = true
                highlight.layer?.cornerRadius = slot * 0.28
                highlight.layer?.cornerCurve = .continuous
                highlight.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.42).cgColor
                highlight.layer?.borderColor = NSColor.gray.withAlphaComponent(0.55).cgColor
                highlight.layer?.borderWidth = 1
                iconRowHost.addSubview(highlight)
            }
            let icon = NSImageView(frame: NSRect(x: x, y: bottomPad, width: slot, height: slot))
            icon.image = sample.icon
            icon.imageScaling = .scaleProportionallyUpOrDown
            iconRowHost.addSubview(icon)
        }

        // 选中应用名（图标下方居中）
        let name = NSTextField(labelWithString: samples[0].name)
        name.font = nameFont
        name.textColor = .labelColor
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(
            x: iconInset, y: s(SwitcherMetrics.nameBottomInset),
            width: rowWidth - iconInset * 2, height: nameHeight
        )
        iconRowHost.addSubview(name)

        // 下挂窗口列表（3 行示例）
        let listWidth = min(s(SwitcherMetrics.listWidthMax), max(s(SwitcherMetrics.listWidthMin), s(260)))
        let listRows = 3
        let list = buildWindowListPreview(
            width: listWidth, rows: listRows,
            rowHeight: s(SwitcherMetrics.rowHeight),
            edgeInset: s(SwitcherMetrics.edgeInset),
            cornerRadius: s(SwitcherMetrics.listCornerRadius),
            font: scaledFont(SwitcherMetrics.listFont)
        )
        list.frame.origin = NSPoint(x: (rowWidth - listWidth) / 2, y: 0)
        iconRow.frame.origin.y = s(SwitcherMetrics.panelGap) + list.frame.height

        let totalWidth = max(rowWidth, listWidth)
        let totalHeight = iconRow.frame.height + s(SwitcherMetrics.panelGap) + list.frame.height
        iconRow.frame.origin.x = (totalWidth - rowWidth) / 2
        contentView.addSubview(list)
        contentView.addSubview(iconRow)
        return NSSize(width: totalWidth, height: totalHeight)
    }

    // MARK: - Cmd+` 窗口面板预览

    private func buildWindowSwitcherPreview() -> NSSize {
        let list = buildWindowListPreview(
            width: s(PanelMetrics.width),
            rows: 4,
            rowHeight: s(PanelMetrics.rowHeight),
            edgeInset: s(PanelMetrics.edgeInset),
            cornerRadius: s(PanelMetrics.cornerRadius),
            font: scaledFont(PanelMetrics.listFont)
        )
        contentView.addSubview(list)
        return list.frame.size
    }

    /// 通用窗口列表面板预览：圆角托盘 + N 行示例（首行高亮）
    private func buildWindowListPreview(
        width: CGFloat, rows: Int, rowHeight: CGFloat,
        edgeInset: CGFloat, cornerRadius: CGFloat, font: NSFont
    ) -> NSView {
        let height = CGFloat(rows) * rowHeight + edgeInset * 2
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let host = Theme.installBackground(on: container, cornerRadius: cornerRadius).contentHost

        let titleHeight = ceil(font.ascender - font.descender + font.leading)
        for index in 0..<rows {
            // 行从顶部往下排（非翻转坐标系：y 大 = 视觉高）
            let rowY = height - edgeInset - CGFloat(index + 1) * rowHeight
            if index == 0 {
                let highlight = NSView(frame: NSRect(
                    x: edgeInset, y: rowY, width: width - edgeInset * 2, height: rowHeight
                ))
                highlight.wantsLayer = true
                highlight.layer?.cornerRadius = 4
                highlight.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
                host.addSubview(highlight)
            }
            let title = NSTextField(labelWithString: "示例窗口 \(index + 1)")
            title.font = font
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingMiddle
            title.frame = NSRect(
                x: edgeInset + 12, y: rowY + (rowHeight - titleHeight) / 2,
                width: width - edgeInset * 2 - 24, height: titleHeight
            )
            host.addSubview(title)
        }
        return container
    }
}
