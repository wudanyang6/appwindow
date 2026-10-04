import ServiceManagement

/// 开机自启动状态（对 SMAppService.Status 的语义化映射）
enum LoginItemState: Equatable {
    case enabled
    case notRegistered
    /// 已注册但被系统挂起：需用户在「系统设置 → 通用 → 登录项」中允许
    case requiresApproval
    case notFound
    /// 系统不支持或调试构建
    case unavailable
}

/// 便于单测注入 fake 的服务抽象
protocol LoginItemServicing {
    var status: LoginItemState { get }
    func register() throws
    func unregister() throws
}

/// 系统实现：SMAppService.mainApp（macOS 13+，主应用自注册，无需 helper）
final class SystemLoginItemService: LoginItemServicing {
    var status: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// 开关语义的薄封装：setEnabled 后由调用方重读 state 刷新 UI；
/// 失败向上抛（设置窗口内联展示，不弹 alert——accessory 应用避免抢焦点）
final class LoginItemManager {
    private let service: LoginItemServicing

    init(service: LoginItemServicing = SystemLoginItemService()) {
        self.service = service
    }

    var state: LoginItemState { service.status }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
