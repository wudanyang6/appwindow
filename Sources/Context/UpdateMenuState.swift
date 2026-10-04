import Foundation

/// 更新菜单状态：驱动菜单标题（检查更新… / 正在检查… / 已是最新 / 有新版本 vX 可用）
enum UpdateMenuState: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case available(version: String)
}

/// 纯状态机（可单测），由 Sparkle 回调驱动：
/// - 换源重试期间保持 checking（不闪回 idle）
/// - 后台检查发现更新后 cycle 结束不清状态，菜单持续提示 available
struct UpdateStateMachine {
    private(set) var state: UpdateMenuState = .idle

    mutating func cycleStarted() {
        state = .checking
    }

    mutating func found(version: String) {
        state = .available(version: version)
    }

    /// isOnLatestVersion=false（系统过旧/过新、硬件不支持等）不冒充「已是最新」，回到 idle
    mutating func notFound(isOnLatestVersion: Bool, currentVersion: String) {
        state = isOnLatestVersion ? .upToDate(version: currentVersion) : .idle
    }

    /// 用户关闭/跳过更新会话：提示完成，回到 idle
    mutating func sessionFinished() {
        state = .idle
    }

    /// 一轮检查结束：重试中保持 checking；否则仅收敛仍处于 checking 的状态，
    /// 不覆盖 available / upToDate（那是本次检查的有效结果）
    mutating func cycleFinished(retrying: Bool) {
        guard !retrying else { return }
        if state == .checking {
            state = .idle
        }
    }

    mutating func reset() {
        state = .idle
    }
}
