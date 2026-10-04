import AppKit
import Sparkle

/// Sparkle 自动更新：手动持有 SPUUpdater（非 SPUStandardUpdaterController），
/// 由 AppDelegate 创建并持有。appcast 与 DMG 经 UpdateSourceFallback 逐源回退；
/// accessory 应用在更新 UI 出现期间临时切 regular 拿 Dock 图标把窗口带到前台
final class UpdaterManager: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    private var updateSourceFallback = UpdateSourceFallback()
    private var isPresentingUpdateUI = false
    /// 抑制错误后即将换源重试：会话结束回调暂不还原激活策略，避免 Dock 图标闪动
    private var isRetryPending = false

    /// 菜单状态机：驱动「检查更新…」菜单标题；变化时主线程回调
    private var stateMachine = UpdateStateMachine()
    var onStateChanged: ((UpdateMenuState) -> Void)?
    var updateMenuState: UpdateMenuState { stateMachine.state }

    private lazy var userDriver: UpdateFallbackUserDriver = {
        let driver = UpdateFallbackUserDriver(hostBundle: .main, delegate: self)
        driver.shouldSuppressUpdaterError = { [weak self] error in
            guard let self, self.updateSourceFallback.canAdvanceAfterError(error) else {
                return false
            }
            self.isRetryPending = true
            return true
        }
        return driver
    }()

    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: userDriver,
        delegate: self
    )

    /// 菜单校验：检查进行中时置灰入口（Sparkle 要求 canCheckForUpdates 为 true 才能调用）
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    /// 自动检查偏好由 Sparkle 自己持久化，直接读写其属性，避免双份状态
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        #if DEBUG
        // 调试构建（swift run / 测试）没有组装 bundle 与 SUFeedURL，跳过以免误报
        return
        #else
        do {
            try updater.start()
        } catch {
            DiagLog.log("update", "启动失败: \(error)")
        }
        #endif
    }

    func checkForUpdates() {
        #if DEBUG
        return
        #else
        guard updater.canCheckForUpdates else { return }

        beginUpdatePresentation()
        // 更新已在展示时点击只是把会话带回前台：Sparkle 不会发起新 cycle（也就没有结束回调），
        // 此时不能进入「正在检查」，否则状态永远停在 checking
        if !updater.sessionInProgress {
            transition { $0.cycleStarted() }
        }
        updater.checkForUpdates()
        #endif
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        transition { $0.found(version: item.displayVersionString) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // 「已是最新」与「系统不满足」要分开：后者不冒充已是最新
        let nsError = error as NSError
        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        let isOnLatestVersion = reason == .onLatestVersion || reason == .onNewerThanLatestVersion
        transition {
            $0.notFound(isOnLatestVersion: isOnLatestVersion, currentVersion: Self.currentShortVersion)
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard
            let directURLString = Bundle.main.object(
                forInfoDictionaryKey: "SUFeedURL"
            ) as? String
        else {
            return nil
        }

        return updateSourceFallback.appcastURLString(from: directURLString)
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        guard let fileURL = item.fileURL else { return }
        request.url = updateSourceFallback.downloadURL(for: fileURL)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if updateSourceFallback.advanceAfterError(error) {
            DiagLog.log("update", "换源重试: \(updateSourceFallback.currentSource)")
            transition { $0.cycleFinished(retrying: true) }
            retry(updateCheck)
            return
        }

        isRetryPending = false
        transition { $0.cycleFinished(retrying: false) }
        endUpdatePresentation()
    }

    private func retry(_ updateCheck: SPUUpdateCheck) {
        switch updateCheck {
        case .updates:
            updater.checkForUpdates()
        case .updatesInBackground:
            updater.checkForUpdatesInBackground()
        default:
            break
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// 后台检查发现更新时同样需要前置窗口（手动检查已在 checkForUpdates 里 begin）
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        beginUpdatePresentation()
    }

    func standardUserDriverWillFinishUpdateSession() {
        // 换源重试中的「会话结束」只是错误弹窗被抑制，不代表用户看到了结果，不更新菜单状态
        if !isRetryPending {
            transition { $0.sessionFinished() }
        }
        // 抑制错误后紧接着会换源重试：保持 regular，等重试有结果再还原
        guard !isRetryPending else { return }
        endUpdatePresentation()
    }

    // MARK: - Beta 通道

    /// 参与测试版时允许 beta 通道条目；默认通道始终可见（稳定版更新不受影响），
    /// 空集 = 只看默认通道
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Settings.betaChannel ? ["beta"] : []
    }

    /// 设置窗口切换「参与测试版」后调用：通道集合变化时 Sparkle 会立即补一次后台检查；
    /// 从未检查过（resetUpdateCycle 无基准可比较）时直接做一次静默探测刷新菜单状态
    func betaChannelDidChange() {
        #if !DEBUG
        if updater.lastUpdateCheckDate == nil {
            updater.checkForUpdateInformation()
        } else {
            updater.resetUpdateCycle()
        }
        #endif
    }

    // MARK: - 菜单状态

    private func transition(_ update: (inout UpdateStateMachine) -> Void) {
        let previous = stateMachine.state
        update(&stateMachine)
        guard stateMachine.state != previous else { return }
        onStateChanged?(stateMachine.state)
    }

    private static var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - accessory ⇄ regular 临时切换

    /// 更新窗口前置需要应用拥有 Dock 图标；所有结束路径（成功/失败/取消/错误抑制）
    /// 都必须经 endUpdatePresentation 还原，guard 保证成对
    private func beginUpdatePresentation() {
        guard !isPresentingUpdateUI else { return }
        isPresentingUpdateUI = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func endUpdatePresentation() {
        guard isPresentingUpdateUI else { return }
        isPresentingUpdateUI = false
        NSApp.setActivationPolicy(.accessory)
    }
}
