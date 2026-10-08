import AppKit

/// 面板背后的加强模糊：材质模糊（`NSVisualEffectView`）的半径由系统定死、改不了，
/// 但模糊可以**叠加**——第 1 层用 `behindWindow` 采样窗口背后，之后每层用 `withinWindow`
/// 把上一层的结果再糊一遍，层数越多越糊。全公开 API。
///
/// 为什么不用私有 `CABackdropLayer`：实测（macOS 27）挂私有 `CAFilter` 与公开 `CIGaussianBlur`
/// 都不生效——层照样把**未模糊**的背后内容画出来（「半径拉满，背后的字还是清晰」），
/// 而且它还会抢走同窗口材质的背后采样。不再走那条路
enum BackdropBlur {

    /// 单层材质模糊的等效半径（约值）：强度按它换算成叠层数
    private static let radiusPerLayer: CGFloat = 16
    private static let maxLayers = 6

    /// 半径（pt）→ 额外叠层数；0 = 不加层（只剩基础毛玻璃那一层）
    static func extraLayerCount(forRadius radius: CGFloat) -> Int {
        guard radius > 0 else { return 0 }
        return min(maxLayers, max(1, Int(radius / radiusPerLayer) + 1))
    }

    /// 加强模糊层：叠在基础毛玻璃之上、着色叠层之下。
    /// 材质用 `.underWindowBackground`（以模糊为主、填充极淡）而不是基础层的 `.menu`：
    /// 每层材质都会带自己的填充，叠几层 `.menu` 会把面板压成不透明——「调了模糊度，透明没了」
    static func makeExtraViews(radius: CGFloat, cornerRadius: CGFloat) -> [NSVisualEffectView] {
        (0..<extraLayerCount(forRadius: radius)).map { _ in
            let view = NSVisualEffectView()
            // withinWindow：只糊窗口内它下面的内容（也就是上一层的输出），逐层叠加
            view.blendingMode = .withinWindow
            view.material = .underWindowBackground
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            return view
        }
    }
}
