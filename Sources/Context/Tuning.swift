import Foundation

/// 单个几何参数的存储定义：读取时 clamp、非数值/缺失回退默认、写入也 clamp。
/// defaults 可注入，测试用独立 suite 不污染真实域
struct TuningValue {
    let key: String
    let defaultValue: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let isInteger: Bool
    private let defaults: UserDefaults

    init(
        key: String,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>,
        step: CGFloat = 1,
        isInteger: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.range = range
        self.step = step
        self.isInteger = isInteger
        self.defaults = defaults
    }

    var value: CGFloat {
        get {
            // 必须用 NSNumber 判型：double(forKey:) 对字符串等损坏值返回 0，
            // 会把「损坏」误判成合法值 0
            guard let stored = defaults.object(forKey: key) as? NSNumber else {
                return defaultValue
            }
            return Self.clamp(CGFloat(stored.doubleValue), to: range)
        }
    }

    /// 写入（clamp 后落库）。用方法而非 setter：目录项是 let 绑定的 struct，
    /// setter 语法在 let 上不合法，而 store 是非 mutating 方法
    func store(_ newValue: CGFloat) {
        defaults.set(Double(Self.clamp(newValue, to: range)), forKey: key)
    }

    var intValue: Int {
        Int(value.rounded())
    }

    var isDefault: Bool {
        value == defaultValue
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// 参数目录项：驱动设置窗口 UI 与测试（新增参数只需在 Tuning 里加一行 + 一条 spec）
struct TuningSpec {
    enum Group {
        case common
        case advanced
    }

    let value: TuningValue
    let title: String
    let subtitle: String?
    let group: Group
    let unit: String?
    /// 展示倍率：百分比项 = 100，其余 = 1
    let displayScale: CGFloat

    var formattedValue: String {
        "\(Int((value.value * displayScale).rounded()))\(unit ?? "")"
    }
}

/// 面板几何参数目录：默认值即当前设计基线（改造时与旧硬编码常量一致，
/// 之后按实测反馈微调过：圆角 26→40、图标行内边距 24→36 等；
/// 2026-10 对系统 cmd+tab 做了一次像素级实拍校准：图标 154→90、间距 12→5、侧边留白 48→36、
/// 应用名 12→13 与底部留白 5→6——校准依据与测量脚本见 docs 或会话记录）
enum Tuning {
    static let iconSizeMax = TuningValue(key: "tuning.iconSizeMax", default: 90, range: 72...256, step: 2)
    static let rowHeight = TuningValue(key: "tuning.rowHeight", default: 34, range: 20...80, step: 1, isInteger: true)
    static let maxListRows = TuningValue(key: "tuning.maxListRows", default: 8, range: 1...20, step: 1, isInteger: true)
    static let panelWidth = TuningValue(key: "tuning.panelWidth", default: 520, range: 300...1200, step: 10, isInteger: true)
    static let listFontSize = TuningValue(key: "tuning.listFontSize", default: 13, range: 10...20, step: 1, isInteger: true)
    static let iconGap = TuningValue(key: "tuning.iconGap", default: 5, range: 0...48, step: 1)
    static let cornerRadius = TuningValue(key: "tuning.cornerRadius", default: 40, range: 0...48, step: 1)
    static let listCornerRadius = TuningValue(key: "tuning.listCornerRadius", default: 16, range: 0...48, step: 1)
    static let iconSizeMin = TuningValue(key: "tuning.iconSizeMin", default: 0, range: 0...200, step: 2)
    static let iconInset = TuningValue(key: "tuning.iconInset", default: 28, range: 0...64, step: 2)
    static let backdropBlurRadius = TuningValue(key: "tuning.backdropBlurRadius", default: 0, range: 0...64, step: 2)
    static let panelVerticalPadding = TuningValue(key: "tuning.panelVerticalPadding", default: 4, range: 0...40, step: 2)
    static let panelSideMargin = TuningValue(key: "tuning.panelSideMargin", default: 87, range: 0...200, step: 2)
    static let panelGap = TuningValue(key: "tuning.panelGap", default: 6, range: 0...40, step: 1)
    static let edgeInset = TuningValue(key: "tuning.edgeInset", default: 8, range: 0...24, step: 1)
    static let listWidthMin = TuningValue(key: "tuning.listWidthMin", default: 180, range: 120...400, step: 4)
    static let listWidthMax = TuningValue(key: "tuning.listWidthMax", default: 360, range: 200...800, step: 8)
    static let listWidthPadding = TuningValue(key: "tuning.listWidthPadding", default: 54, range: 20...120, step: 2)
    static let nameFontSize = TuningValue(key: "tuning.nameFontSize", default: 13, range: 8...20, step: 1, isInteger: true)
    static let nameGap = TuningValue(key: "tuning.nameGap", default: 1, range: 0...20, step: 1)
    static let nameBottomInset = TuningValue(key: "tuning.nameBottomInset", default: 6, range: 0...30, step: 1)
    static let heightRatio = TuningValue(key: "tuning.heightRatio", default: 0.70, range: 0.30...0.95, step: 0.05)

    static let all: [TuningSpec] = [
        TuningSpec(value: iconSizeMax, title: "图标最大尺寸", subtitle: nil, group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: rowHeight, title: "列表行高", subtitle: nil, group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: maxListRows, title: "列表最大行数", subtitle: nil, group: .common, unit: "行", displayScale: 1),
        TuningSpec(value: panelWidth, title: "面板宽度", subtitle: nil, group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: listFontSize, title: "列表字号", subtitle: nil, group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: iconGap, title: "图标间距", subtitle: nil, group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: cornerRadius, title: "图标面板圆角", subtitle: nil, group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: listCornerRadius, title: "列表圆角", subtitle: nil, group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: iconSizeMin, title: "图标最小尺寸", subtitle: "应用多到图标被压缩时才生效；0 = 不限制", group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: iconInset, title: "图标行内边距", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: panelVerticalPadding, title: "面板上下留白",
                   subtitle: "图标托盘在名称区之外额外加的高度（上下对称）；只影响托盘高度",
                   group: .common, unit: "pt", displayScale: 1),
        TuningSpec(value: backdropBlurRadius, title: "面板背后模糊加强",
                   subtitle: "叠模糊层数：每 16pt 加一层，层数越多越糊；0 = 不额外加层",
                   group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: panelSideMargin, title: "面板侧边留白", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: panelGap, title: "面板间距", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: edgeInset, title: "列表内边距", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: listWidthMin, title: "列表最小宽度", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: listWidthMax, title: "列表最大宽度", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: listWidthPadding, title: "列表标题余量", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: nameFontSize, title: "应用名字号", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: nameGap, title: "名称间距", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: nameBottomInset, title: "名称底部留白", subtitle: nil, group: .advanced, unit: "pt", displayScale: 1),
        TuningSpec(value: heightRatio, title: "窗口面板高度比例", subtitle: "窗口数超过该比例对应的行数时才滚动，窗口少时无感", group: .advanced, unit: "%", displayScale: 100)
    ]

    static var common: [TuningSpec] {
        all.filter { $0.group == .common }
    }

    static var advanced: [TuningSpec] {
        all.filter { $0.group == .advanced }
    }

    static func resetAll() {
        all.forEach { $0.value.reset() }
    }
}
