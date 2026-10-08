import XCTest
import AppKit
@testable import AppWindow

/// 回归：图标行的几何跟随。面板容器跨会话复用，复用分支曾经只更新选中态——
/// 调「左右留白 / 图标尺寸」时容器与窗口按新几何变化、槽位却停在旧几何，表现为图标错位/尺寸不对
final class AppSwitcherPanelLayoutTests: XCTestCase {

    override func tearDown() {
        Tuning.iconInset.reset()
        Tuning.iconSizeMax.reset()
        Tuning.iconSizeMin.reset()
        super.tearDown()
    }

    func testIconRowFollowsGeometryChange() throws {
        // 测试进程里 NSApp 全局要首次访问 NSApplication.shared 才会被赋值；
        // 面板构建会走 NSApp.windows（幽灵清扫），不先初始化会崩
        _ = NSApplication.shared

        let apps = WindowListService.switcherApps()
        try XCTSkipIf(apps.count < 2, "测试进程内可见应用不足两个，跳过")

        let panel = AppSwitcherPanel()
        func prepare() {
            panel.prepare(apps: apps, appIndex: 0, windows: [], windowIndex: nil,
                          badges: apps.map { _ in nil },
                          onPickApp: { _ in }, onHoverApp: { _ in },
                          onPickWindow: { _ in }, onHoverWindow: { _ in },
                          onScrollApp: { _ in }, onCancel: {})
        }

        prepare()
        let base = panel.iconSlotFrames
        XCTAssertEqual(base.count, apps.count, "每个应用一个槽位")

        // 左右留白（只改位置）：槽位要重排到新位置，且间距关系不变
        let gapBefore = base.count >= 2 ? base[1].minX - base[0].minX : 0
        Tuning.iconInset.store(Tuning.iconInset.value + 10)
        prepare()
        let moved = panel.iconSlotFrames
        XCTAssertEqual(moved.count, base.count)
        XCTAssertGreaterThan(moved[0].minX, base[0].minX, "留白变大后首槽位应右移")
        if base.count >= 2 {
            XCTAssertEqual(moved[1].minX - moved[0].minX, gapBefore, accuracy: 0.01,
                           "留白变化不应改变相邻槽位间距")
        }

        // 槽位边长变化：槽位内部几何（图标视图 frame、角标尺寸）在 init 时定死，必须重建才能跟上。
        // 用「图标最小尺寸」把槽位从宽度约束值抬起来——应用多时槽位由可用宽度绑死，
        // 改「图标最大尺寸」抬不动（它的下限 72 已高于宽度约束值）
        let sideBefore = moved[0].width
        Tuning.iconSizeMin.store(sideBefore + 20)
        prepare()
        let resized = panel.iconSlotFrames
        XCTAssertGreaterThan(resized[0].width, sideBefore + 10,
                             "槽位边长变化后应重建槽位（复用分支需要按新边长重建）")
    }
}
