import Foundation
import Sparkle

/// 换源重试期间抑制 Sparkle 的错误弹窗：重试由 UpdaterManager 自动进行，
/// 用户只在所有源都失败后看到最终错误。
/// presentUpdaterError 可注入，便于单测不弹真窗
final class UpdateFallbackUserDriver: SPUStandardUserDriver {
    var shouldSuppressUpdaterError: ((Error) -> Bool)?

    private let presentUpdaterError: ((Error, @escaping () -> Void) -> Void)?

    init(
        hostBundle: Bundle,
        delegate: SPUStandardUserDriverDelegate?,
        presentUpdaterError: ((Error, @escaping () -> Void) -> Void)? = nil
    ) {
        self.presentUpdaterError = presentUpdaterError
        super.init(hostBundle: hostBundle, delegate: delegate)
    }

    override func showUpdaterError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        if shouldSuppressUpdaterError?(error) == true {
            acknowledgement()
            return
        }

        if let presentUpdaterError {
            presentUpdaterError(error, acknowledgement)
        } else {
            super.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }
}
