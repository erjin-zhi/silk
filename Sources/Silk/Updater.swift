import AppKit
import Sparkle

/// 自动更新，用 Sparkle 实现。
///
/// 更新源和验签公钥写在 Info.plist 里（SUFeedURL、SUPublicEDKey）。只有从 Silk.app 运行时才启动：
/// `swift run`、跑测试时没有 App 包，Sparkle 起不来，「检查更新…」显示为不可用。
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// 检查结束（不管有没有新版本、成没成功）后发出，关于窗口借此刷新「上次检查」。
    static let didFinishCheck = Notification.Name("SilkUpdaterDidFinishCheck")

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    /// 没能启动的原因，关于窗口里显示给用户看。
    private(set) var unavailableReason: String?

    var isAvailable: Bool { updater != nil }
    var canCheckForUpdates: Bool { updater?.canCheckForUpdates ?? false }
    var lastCheckDate: Date? { updater?.lastUpdateCheckDate }
    var allowsAutomaticDownloads: Bool { updater?.allowsAutomaticUpdates ?? false }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    /// 启动时调用一次。按 Info.plist 的设置在后台定期检查（默认每天一次）。
    func start(bundle: Bundle = .main) {
        guard updater == nil else { return }
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else {
            unavailableReason = "从 Silk.app 运行时才能检查更新"
            return
        }
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              bundle.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            unavailableReason = "这个版本没有配置更新源"
            return
        }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            userDriver = driver
            unavailableReason = nil
        } catch {
            unavailableReason = "更新组件没能启动：\(error.localizedDescription)"
            DebugHooks.log("Sparkle 启动失败：\(error)")
        }
    }

    /// 用户点「检查更新…」：弹出 Sparkle 的进度和结果窗口。
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// 不弹窗口在后台检查，调试用。开着「自动下载并安装」时会直接下载，退出时装上。
    func checkInBackground() {
        updater?.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor in NotificationCenter.default.post(name: Self.didFinishCheck, object: self) }
    }
}
