import XCTest
import AppKit
@testable import AppWindow

/// 背景装配契约：玻璃分支的毛玻璃垫层可配置（按开关增减 NSVisualEffectView）
final class ThemeBackgroundTests: XCTestCase {

    override func tearDown() {
        // 测试写的是测试进程自己的 defaults 域；恢复默认避免用例互相干扰
        Settings.glassUnderBlurStrength = 1
        Settings.glassMode = .regular
        super.tearDown()
    }

    @available(macOS 26.0, *)
    func testUnderGlassBlurFollowsStrength() {
        Settings.glassMode = .regular

        Settings.glassUnderBlurStrength = 0.5
        let half = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        _ = Theme.installBackground(on: half, cornerRadius: 10)
        XCTAssertEqual(countBlurViews(in: half), 1, "强度 > 0 时应装配垫层")
        XCTAssertEqual(blurView(in: half)?.alphaValue ?? 0, 0.5, accuracy: 0.001,
                       "垫层不透明度应等于配置强度（观感即模糊度）")

        Settings.glassUnderBlurStrength = 0
        let off = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        _ = Theme.installBackground(on: off, cornerRadius: 10)
        XCTAssertEqual(countBlurViews(in: off), 0, "强度 0 = 关闭，不应有 NSVisualEffectView")
    }

    /// 旧开关迁移：false → 0%、true → 100%、都未设置过 → 默认 100%；新键优先于旧键
    func testGlassBlurStrengthMigratesFromLegacySwitch() {
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: "glassUnderBlurStrength")
            defaults.removeObject(forKey: "glassUnderBlurEnabled")
        }
        defaults.removeObject(forKey: "glassUnderBlurStrength")
        defaults.removeObject(forKey: "glassUnderBlurEnabled")
        XCTAssertEqual(Settings.glassUnderBlurStrength, 1, "未设置过时应为默认 100%")

        defaults.set(false, forKey: "glassUnderBlurEnabled")
        XCTAssertEqual(Settings.glassUnderBlurStrength, 0, "旧开关关闭 → 0%")

        defaults.set(true, forKey: "glassUnderBlurEnabled")
        XCTAssertEqual(Settings.glassUnderBlurStrength, 1, "旧开关开启 → 100%")

        defaults.set(0.4, forKey: "glassUnderBlurStrength")
        XCTAssertEqual(Settings.glassUnderBlurStrength, 0.4, accuracy: 0.0001, "新键优先于旧键")
    }

    // MARK: - 内容层与背景层分离（回归）

    /// 回归：面板复用容器时「清空 contentHost.subviews 重建内容」不得移除任何背景层。
    /// 旧结构下 contentHost 就是容器本身（非玻璃分支），清空会把毛玻璃与暗色叠层一并删掉
    func testClearingContentHostKeepsBackgroundLayers() {
        Settings.glassMode = .off
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

    /// 回归（Clear 玻璃下切换应用后下拉列表可读性变差的根因）：旧结构 contentHost 直接是
    /// glass.contentView，清空内容会连自适应垫层一起删掉。新结构下垫层是内容宿主的祖先
    @available(macOS 26.0, *)
    func testClearingContentHostKeepsGlassScrim() {
        Settings.glassMode = .clear
        Settings.glassUnderBlurStrength = 0
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        let background = Theme.installBackground(on: container, cornerRadius: 10)

        guard let glass = background.materials.compactMap({ $0 as? NSGlassEffectView }).first,
              let glassContent = glass.contentView else {
            return XCTFail("Clear 模式应装配带 contentView 的 NSGlassEffectView")
        }
        XCTAssertFalse(background.contentHost === glassContent,
                       "内容宿主不能直接是玻璃 contentView（否则清内容会删掉垫层）")
        XCTAssertTrue(isDescendant(background.contentHost, of: glass), "内容宿主必须在玻璃内合成")
        XCTAssertTrue(containsBackgroundFill(glassContent), "玻璃 contentView 内应有垫层")

        background.contentHost.addSubview(NSView(frame: container.bounds))
        background.contentHost.subviews.forEach { $0.removeFromSuperview() }

        XCTAssertTrue(containsBackgroundFill(glassContent), "清空内容后垫层仍应存在")
        XCTAssertTrue(isDescendant(background.contentHost, of: glass), "清空内容后内容宿主仍在玻璃内")
    }

    private func countBlurViews(in container: NSView) -> Int {
        container.subviews.filter { $0 is NSVisualEffectView }.count
    }

    private func blurView(in container: NSView) -> NSVisualEffectView? {
        container.subviews.compactMap { $0 as? NSVisualEffectView }.first
    }

    /// view 的祖先链中是否存在 ancestor
    private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var node = view.superview
        while let current = node {
            if current === ancestor { return true }
            node = current.superview
        }
        return false
    }

    /// 视图树中是否存在带背景填充的层（垫层 / 暗色叠层）
    private func containsBackgroundFill(_ view: NSView) -> Bool {
        if view.wantsLayer, view.layer?.backgroundColor != nil { return true }
        return view.subviews.contains { containsBackgroundFill($0) }
    }
}
