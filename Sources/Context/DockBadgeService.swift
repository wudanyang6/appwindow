import AppKit
import ApplicationServices

/// 读取 Dock 角标（未读消息数等）：Dock 的 AX 树里每个 dock item 带
/// AXStatusLabel（角标文字），应用自己通过 NSDockTile.badgeLabel 设置。
/// dock item 的 AXTitle 与 localizedName 基本一致（如流、微信、Google Chrome），
/// 个别应用有偏差（iTerm 的 dock title 是 "iTerm"），失配的拿不到角标，
/// 但有角标需求的应用（IM 类）命名一致，可接受。
/// AX 调用可跨线程，面板打开时后台读取避免卡首按。
enum DockBadgeService {

    private static let axTimeout: Float = 0.5

    /// 返回有角标的应用：dock title → 角标文字（空角标不收录）
    static func badgeByTitle() -> [String: String] {
        guard let dock = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" }) else { return [:] }
        let axDock = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(axDock, axTimeout)

        guard let list = axDock.children.first else { return [:] }
        var badges: [String: String] = [:]
        for item in list.children {
            // 只认运行中 app 的 dock item：iPhone 接力 item 与真实 app 同名（如"提醒事项"），
            // 其 statusLabel 是设备标识（com.apple.iphone-…），会覆盖同名 app 的真实未读数
            guard item.subrole == "AXApplicationDockItem" else { continue }
            let title = item.title ?? ""
            guard !title.isEmpty, let status = item.statusLabel, !status.isEmpty else { continue }
            badges[title] = status
        }
        return badges
    }
}

private extension AXUIElement {

    /// Dock 的 children 是单层容器，真正的 dock items 在容器之下
    var children: [AXUIElement] {
        copyAttribute(kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// dock item 的角标文字（AXStatusLabel），无角标时为空或缺失
    var statusLabel: String? {
        copyAttribute("AXStatusLabel") as? String
    }
}
