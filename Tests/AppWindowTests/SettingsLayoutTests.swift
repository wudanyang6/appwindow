import XCTest
import AppKit
@testable import AppWindow

/// 设置窗口布局回归：Tab 分组显隐、分组撑满宽度、几何控件齐全、高级折叠、窗口高度封顶。
/// 曾出过的问题：依赖 NSStackView 的 .width 对齐，窄分组按 intrinsic 宽度缩在中间
final class SettingsLayoutTests: XCTestCase {

    private func makeController() -> SettingsWindowController {
        SettingsWindowController(
            updaterManager: UpdaterManager(),
            eventTapManager: EventTapManager(panel: SwitchPanel()),
            isAccessibilityGranted: { true }
        )
    }

    private func contentStack(of controller: SettingsWindowController) throws -> NSStackView {
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        // 内容放在滚动容器的 documentView 里（小屏时窗口高度按屏幕封顶）
        let scrollView = try XCTUnwrap(
            content.subviews.compactMap { $0 as? NSScrollView }.first,
            "滚动容器应存在"
        )
        let documentView = try XCTUnwrap(scrollView.documentView)
        documentView.layoutSubtreeIfNeeded()
        return try XCTUnwrap(
            documentView.subviews.compactMap { $0 as? NSStackView }.first,
            "内容栈应存在"
        )
    }

    private func findView<T: NSView>(_ type: T.Type, in view: NSView, where predicate: (T) -> Bool) -> T? {
        if let match = view as? T, predicate(match) { return match }
        for subview in view.subviews {
            if let found = findView(type, in: subview, where: predicate) { return found }
        }
        return nil
    }

    private func makeRoots() throws -> (controller: SettingsWindowController, stack: NSStackView, tabs: NSSegmentedControl) {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let tabs = try XCTUnwrap(
            findView(NSSegmentedControl.self, in: content, where: { $0.segmentCount > 0 }),
            "Tab 分段控件应存在"
        )
        let stack = try contentStack(of: controller)
        return (controller, stack, tabs)
    }

    private func selectTab(_ tabs: NSSegmentedControl, _ index: Int) {
        tabs.selectedSegment = index
        tabs.sendAction(tabs.action, to: tabs.target)
    }

    func testTabsShowOnlyTheirSections() throws {
        let (_, stack, tabs) = try makeRoots()
        XCTAssertEqual(stack.arrangedSubviews.count, 6, "应有 通用/更新/快捷键/预览/面板几何/高级几何 六个分组")
        XCTAssertEqual(tabs.segmentCount, 4, "应有 通用/更新/快捷键/面板与图标 四个 Tab")

        // 初始（通用 Tab）：只有第 0 个分组可见
        XCTAssertFalse(stack.arrangedSubviews[0].isHidden)
        for section in stack.arrangedSubviews.dropFirst() {
            XCTAssertTrue(section.isHidden, "非当前 Tab 的分组应隐藏")
        }

        // 切到「面板与图标」：预览 + 几何分组可见；高级分组仍受折叠开关约束
        selectTab(tabs, 3)
        XCTAssertTrue(stack.arrangedSubviews[0].isHidden)
        XCTAssertFalse(stack.arrangedSubviews[3].isHidden, "预览分组应可见")
        XCTAssertFalse(stack.arrangedSubviews[4].isHidden, "几何分组应可见")
        XCTAssertTrue(stack.arrangedSubviews[5].isHidden, "高级分组默认仍折叠")

        // 切回通用
        selectTab(tabs, 0)
        XCTAssertFalse(stack.arrangedSubviews[0].isHidden)
        XCTAssertTrue(stack.arrangedSubviews[4].isHidden)
    }

    func testSectionsFillContainerWidth() throws {
        let (_, stack, tabs) = try makeRoots()

        // 逐个 Tab 检查可见分组的宽度（隐藏的 arranged subview 会被 NSStackView 移出布局）
        for tab in 0..<tabs.segmentCount {
            selectTab(tabs, tab)
            stack.layoutSubtreeIfNeeded()
            for section in stack.arrangedSubviews where !section.isHidden {
                XCTAssertEqual(
                    section.frame.width, stack.frame.width, accuracy: 0.5,
                    "Tab \(tab) 的每个可见分组都应撑满容器宽度（不得按 intrinsic 宽度缩进）"
                )
            }
        }
    }

    func testGeometryControlsCoverAllTuningParameters() throws {
        let (_, stack, _) = try makeRoots()

        // 只统计「面板与图标」Tab 的两个几何分组：通用分组里有垫层强度滑杆等其他滑杆，
        // 全窗计数会把它们算进来（曾因此误报 21 != 20）
        let geometry = stack.arrangedSubviews[4]
        let advanced = stack.arrangedSubviews[5]
        let sliders = countSubviews(ofType: NSSlider.self, in: geometry)
            + countSubviews(ofType: NSSlider.self, in: advanced)
        XCTAssertEqual(sliders, Tuning.all.count, "每个几何参数都应有一个滑杆")
    }

    /// 通用 Tab 的垫层强度滑杆应反映存储值（0–1 连续值，0 = 关闭）
    func testBlurStrengthSliderReflectsStoredValue() throws {
        Settings.glassUnderBlurStrength = 0.25
        defer { Settings.glassUnderBlurStrength = 1 }

        let (_, stack, _) = try makeRoots()
        let slider = try XCTUnwrap(
            findView(NSSlider.self, in: stack.arrangedSubviews[0], where: { $0.minValue == 0 && $0.maxValue == 1 }),
            "通用分组应存在垫层强度滑杆"
        )
        XCTAssertEqual(slider.doubleValue, 0.25, accuracy: 0.0001)
    }

    func testAdvancedToggleExpandsAndCollapsesSection() throws {
        let (_, stack, tabs) = try makeRoots()
        selectTab(tabs, 3)
        let advanced = stack.arrangedSubviews[5]

        let checkbox = try XCTUnwrap(
            findView(NSButton.self, in: stack, where: { $0.title == "显示高级参数" }),
            "应存在高级参数勾选框"
        )
        checkbox.performClick(nil)
        XCTAssertFalse(advanced.isHidden, "勾选后高级几何应展开")

        checkbox.performClick(nil)
        XCTAssertTrue(advanced.isHidden, "取消勾选后应重新折叠")
    }

    func testWindowHeightCappedByScreen() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        XCTAssertLessThanOrEqual(content.frame.height, screenHeight * 0.9 + 1)
    }

    /// 固定窗宽：长副标题不得把窗口最小宽度撑大（标签压缩阻力须允许截断）
    func testWindowWidthIsFixed() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.frame.width, 560, accuracy: 0.5)
    }

    /// 玻璃模式控件应反映存储的档位（构建路径）
    func testGlassControlReflectsStoredMode() throws {
        Settings.glassMode = .clear
        defer { Settings.glassMode = .regular }

        let controller = makeController()
        let content = try XCTUnwrap(controller.window?.contentView)
        let glassControl = try XCTUnwrap(
            findView(NSSegmentedControl.self, in: content, where: { $0.segmentCount == 3 }),
            "应存在 3 段玻璃模式控件"
        )
        XCTAssertEqual(glassControl.selectedSegment, 1, "存储 clear 时控件应选中第 2 段")
    }

    /// 玻璃模式切换会重建背景材质：材质必须重排到最底层，不得盖住 Tab 控件
    /// （曾出过：材质只放到滚动视图之下，把位于其间的 Tab 分段控件遮住）
    func testGlassModeSwitchKeepsTabControlOnTop() throws {
        let controller = makeController()
        let content = try XCTUnwrap(controller.window?.contentView)
        let tabs = try XCTUnwrap(
            findView(NSSegmentedControl.self, in: content, where: { $0.segmentCount == 4 }),
            "应存在 4 段 Tab 控件"
        )
        let glassControl = try XCTUnwrap(
            findView(NSSegmentedControl.self, in: content, where: { $0.segmentCount == 3 }),
            "应存在 3 段玻璃模式控件"
        )

        // 切一次玻璃模式，触发 rebuildBackground
        glassControl.selectedSegment = (glassControl.selectedSegment + 1) % 3
        glassControl.sendAction(glassControl.action, to: glassControl.target)

        guard let tabsIndex = content.subviews.firstIndex(of: tabs) else {
            return XCTFail("Tab 控件不在内容视图里")
        }
        // 除 Tab 控件与滚动容器外的子视图即材质层，必须都排在 Tab 控件之前（更底层）
        for (index, view) in content.subviews.enumerated()
        where view !== tabs && !(view is NSScrollView) {
            XCTAssertLessThan(index, tabsIndex, "材质视图必须位于 Tab 控件之下，否则会遮住 Tab")
        }
    }

    private func countSubviews<T: NSView>(ofType type: T.Type, in view: NSView) -> Int {
        view.subviews.reduce(0) { count, subview in
            count + (subview is T ? 1 : 0) + countSubviews(ofType: type, in: subview)
        }
    }
}
