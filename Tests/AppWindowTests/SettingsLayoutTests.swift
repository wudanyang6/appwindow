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

    private func findViews<T: NSView>(_ type: T.Type, in view: NSView, where predicate: (T) -> Bool) -> [T] {
        var found: [T] = []
        if let match = view as? T, predicate(match) { found.append(match) }
        for subview in view.subviews {
            found.append(contentsOf: findViews(type, in: subview, where: predicate))
        }
        return found
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
        // 分组顺序：行为 / 外观 / 启动与诊断 / 面板几何 / 高级几何 / 快捷键 / 更新
        XCTAssertEqual(stack.arrangedSubviews.count, 7, "应有七个分组")
        XCTAssertEqual(tabs.segmentCount, 4, "应有 通用/面板/快捷键/更新 四个 Tab")

        // 初始（通用 Tab）：前三个分组可见（行为 / 外观 / 启动与诊断）
        for index in 0..<3 {
            XCTAssertFalse(stack.arrangedSubviews[index].isHidden, "通用 Tab 的第 \(index) 个分组应可见")
        }
        for section in stack.arrangedSubviews.dropFirst(3) {
            XCTAssertTrue(section.isHidden, "非当前 Tab 的分组应隐藏")
        }

        // 面板 Tab：面板几何与高级几何同页（分两组呈现）
        selectTab(tabs, 1)
        XCTAssertFalse(stack.arrangedSubviews[3].isHidden, "面板几何应可见")
        XCTAssertFalse(stack.arrangedSubviews[4].isHidden, "高级几何应与面板几何同页可见")
        XCTAssertTrue(stack.arrangedSubviews[0].isHidden, "通用分组不该在面板 Tab 显示")

        // 切回通用
        selectTab(tabs, 0)
        XCTAssertFalse(stack.arrangedSubviews[0].isHidden)
        XCTAssertTrue(stack.arrangedSubviews[3].isHidden)
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

        // 只统计「面板几何 + 高级几何」两个分组：通用 Tab 里有面板不透明度等着色滑杆，
        // 全窗计数会把它们算进来
        let geometry = stack.arrangedSubviews[3]
        let advanced = stack.arrangedSubviews[4]
        let sliders = countSubviews(ofType: NSSlider.self, in: geometry)
            + countSubviews(ofType: NSSlider.self, in: advanced)
        XCTAssertEqual(sliders, Tuning.all.count, "每个几何参数都应有一个滑杆")
    }

    /// 通用 Tab 的面板不透明度滑杆应反映存储值（0–1 连续值，1 = 最不透明）
    func testPanelAlphaSliderReflectsStoredValue() throws {
        Settings.panelAlpha = 0.25
        defer { Settings.panelAlpha = 1 }

        let (_, stack, _) = try makeRoots()
        let sliders = findViews(NSSlider.self, in: stack.arrangedSubviews[1],
                                where: { $0.minValue == 0 && $0.maxValue == 1 })
        XCTAssertTrue(sliders.contains { abs($0.doubleValue - 0.25) < 0.0001 },
                      "外观分组应有滑杆显示存储的不透明度 0.25")
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

    /// 背景材质重建后仍须排在最底层，不得盖住 Tab 控件
    /// （曾出过：材质只放到滚动视图之下，把位于其间的 Tab 分段控件遮住）
    func testBackgroundRebuildKeepsTabControlOnTop() throws {
        let controller = makeController()
        let content = try XCTUnwrap(controller.window?.contentView)
        let tabs = try XCTUnwrap(
            findView(NSSegmentedControl.self, in: content, where: { $0.segmentCount == 4 }),
            "应存在 4 段 Tab 控件"
        )
        let slider = try XCTUnwrap(
            findView(NSSlider.self, in: content, where: { $0.minValue == 0 && $0.maxValue == 1 }),
            "通用分组应存在背景滑杆"
        )

        // 拖一次滑杆，触发 rebuildBackground
        slider.doubleValue = 0.6
        slider.sendAction(slider.action, to: slider.target)

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
