import XCTest
import AppKit
@testable import AppWindow

/// 背景装配契约：毛玻璃层 + 可选加强模糊层 + 暗色叠层，以及面板外观偏好
final class ThemeBackgroundTests: XCTestCase {

    override func tearDown() {
        // 测试写的是测试进程自己的 defaults 域；恢复默认避免用例互相干扰
        UserDefaults.standard.removeObject(forKey: "panelTintAlpha")
        UserDefaults.standard.removeObject(forKey: "panelAlpha")
        super.tearDown()
    }

    /// 面板着色量：默认取校准值 12%、越界钳制
    func testPanelTintAlphaSetting() {
        UserDefaults.standard.removeObject(forKey: "panelTintAlpha")
        XCTAssertEqual(Settings.panelTintAlpha, 0.12, accuracy: 0.0001, "未设置过时用校准默认值")

        Settings.panelTintAlpha = 0.3
        XCTAssertEqual(Settings.panelTintAlpha, 0.3, accuracy: 0.0001)
        Settings.panelTintAlpha = 5
        XCTAssertEqual(Settings.panelTintAlpha, 1, accuracy: 0.0001, "越界钳到 1")
    }

    /// 面板不透明度：默认 1（最不透明）、越界钳制
    func testPanelAlphaSetting() {
        UserDefaults.standard.removeObject(forKey: "panelAlpha")
        XCTAssertEqual(Settings.panelAlpha, 1, accuracy: 0.0001, "未设置过时默认完全不透明")

        Settings.panelAlpha = 0.4
        XCTAssertEqual(Settings.panelAlpha, 0.4, accuracy: 0.0001)
        Settings.panelAlpha = -3
        XCTAssertEqual(Settings.panelAlpha, 0, accuracy: 0.0001, "越界钳到 0")
    }

    /// 面板外观偏好变化要推进背景代次：面板容器跨会话复用，靠它判断材质层要不要重建
    func testPanelSettingsBumpBackgroundGeneration() {
        var previous = Theme.backgroundGeneration

        Settings.panelTintAlpha = 0.2
        XCTAssertGreaterThan(Theme.backgroundGeneration, previous, "着色量变化应作废复用缓存")

        previous = Theme.backgroundGeneration
        Settings.panelAlpha = 0.6
        XCTAssertGreaterThan(Theme.backgroundGeneration, previous, "不透明度变化应作废复用缓存")
    }

    /// 高亮配色随外观切换：浅色 = 中灰、暗色 = 白（灰色在暗托盘上对比不足）。
    /// 两色均经实测反馈调过：暗色白值 35%/60% 太扎眼 → 28%；描边两种模式下都读成
    /// 异色圈（浅色黑边、暗色白圈）→ 全部去掉，高亮只剩填充
    func testHighlightsAdaptToAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(Theme.switcherHighlightColor(for: light).cgColor,
                       NSColor.gray.withAlphaComponent(0.42).cgColor)
        XCTAssertEqual(Theme.switcherHighlightColor(for: dark).cgColor,
                       NSColor.white.withAlphaComponent(0.28).cgColor)
        XCTAssertNotEqual(Theme.switcherHighlightColor(for: light).cgColor,
                          Theme.switcherHighlightColor(for: dark).cgColor,
                          "暗色模式应换成对比更高的颜色")

        XCTAssertEqual(Theme.windowRowHighlightColor(for: light).cgColor,
                       NSColor.black.withAlphaComponent(0.20).cgColor)
        XCTAssertEqual(Theme.windowRowHighlightColor(for: dark).cgColor,
                       NSColor.white.withAlphaComponent(0.18).cgColor)
    }

    /// 加强模糊的层数换算：0 = 不加层；越大层数越多（封顶 6 层）
    func testBackdropBlurLayerCount() {
        XCTAssertEqual(BackdropBlur.extraLayerCount(forRadius: 0), 0, "0 = 只用基础毛玻璃")
        XCTAssertEqual(BackdropBlur.extraLayerCount(forRadius: 1), 1, "有值就至少叠一层")
        XCTAssertEqual(BackdropBlur.extraLayerCount(forRadius: 16), 2)
        XCTAssertEqual(BackdropBlur.extraLayerCount(forRadius: 64), 5)
        XCTAssertEqual(BackdropBlur.extraLayerCount(forRadius: 200), 6, "封顶 6 层")

        let views = BackdropBlur.makeExtraViews(radius: 32, cornerRadius: 12)
        XCTAssertEqual(views.count, 3)
        XCTAssertTrue(views.allSatisfy { $0.blendingMode == .withinWindow },
                      "加强层必须 withinWindow：只糊窗口内上一层的结果，逐层叠加")
        XCTAssertTrue(views.allSatisfy { $0.material == .underWindowBackground },
                      "加强层要用最轻的材质：叠 .menu 这类重填充材质会把面板压成不透明")
    }

    /// 装配契约：强度 > 0 时多出加强层，且叠在基础毛玻璃之上；不透明度同时作用到两者
    func testInstallBackgroundAddsExtraBlurLayers() throws {
        Tuning.backdropBlurRadius.store(32)
        Settings.panelAlpha = 0.5
        defer {
            Tuning.backdropBlurRadius.reset()
            Settings.panelAlpha = 1
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        let background = Theme.installBackground(on: container, cornerRadius: 10)
        let blurViews = container.subviews.compactMap { $0 as? NSVisualEffectView }
        XCTAssertEqual(blurViews.count, 1 + 3, "基础毛玻璃 1 层 + 加强 3 层")
        XCTAssertEqual(blurViews.first?.blendingMode, .behindWindow, "最底层负责采样窗口背后")
        XCTAssertTrue(blurViews.allSatisfy { abs($0.alphaValue - 0.5) < 0.001 },
                      "加强层要跟着一起透，否则会把半透明的基础层盖住")
        XCTAssertEqual(background.materials.count, blurViews.count + 1, "材质清单应含全部模糊层 + 叠层")
    }

    // MARK: - 内容层与背景层分离（回归）

    /// 回归：面板复用容器时「清空 contentHost.subviews 重建内容」不得移除任何背景层。
    /// 旧结构下 contentHost 就是容器本身，清空会把毛玻璃与暗色叠层一并删掉
    func testClearingContentHostKeepsBackgroundLayers() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        let background = Theme.installBackground(on: container, cornerRadius: 10)
        XCTAssertFalse(background.contentHost === container, "内容宿主必须是独立层")

        // 模拟复用容器的标准操作：加内容 → 清空 → 重建内容
        background.contentHost.addSubview(NSView(frame: container.bounds))
        background.contentHost.subviews.forEach { $0.removeFromSuperview() }
        background.contentHost.addSubview(NSView(frame: container.bounds))

        XCTAssertEqual(countBlurViews(in: container), 1, "清空内容后毛玻璃层不应被移除")
        XCTAssertEqual(container.subviews.count, 2, "容器直接子视图（模糊 + 叠层）不应因清空内容变化")
        XCTAssertNotNil(background.contentHost.superview, "内容宿主不应脱离视图树")
    }

    private func countBlurViews(in container: NSView) -> Int {
        container.subviews.filter { $0 is NSVisualEffectView }.count
    }
}
