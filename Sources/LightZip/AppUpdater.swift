import AppKit
import Combine
import Sparkle

/// Sparkle owns download, signature verification and atomic app replacement.
/// The app keeps its existing termination/temporary-file cleanup lifecycle.
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Phase {
        case unchecked, checking, available, downloading, verifying, ready, deferred, current, noUpdate, failed, incompatible
    }
    static let shared = AppUpdater()

    @Published private(set) var automaticUpdates = true
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var status = ""
    @Published private(set) var phase: Phase = .unchecked

    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var busyObservation: AnyCancellable?
    private var deferredInstall: (() -> Void)?
    private var started = false

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var shortStatus: String {
        switch phase {
        case .unchecked: return "待检查"
        case .checking: return "检查中"
        case .available: return "有新版本"
        case .downloading: return "下载中"
        case .verifying: return "校验中"
        case .ready: return "待安装"
        case .deferred: return "等待任务完成"
        case .current: return "已是最新"
        case .noUpdate: return "暂无更新"
        case .failed: return "更新失败"
        case .incompatible: return "系统不兼容"
        }
    }

    var statusHelp: String {
        var lines = [status.isEmpty ? "尚未检查新版本" : status]
        lines.append(automaticUpdates ? "运行时每天检查，下载后在退出时安装；不会中断当前任务。" : "自动更新已关闭，仍可手动检查。")
        if let lastCheck { lines.append("上次检查：\(lastCheck.formatted(date: .abbreviated, time: .shortened))") }
        return lines.joined(separator: "\n")
    }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        ]
        busyObservation = AppModel.shared.$busy.removeDuplicates().sink { [weak self] busy in
            // @Published emits before the model changes. Recheck on the next turn.
            guard !busy else { return }
            Task { @MainActor in
                guard let self, !AppModel.shared.busy, let install = self.deferredInstall else { return }
                self.deferredInstall = nil
                install()
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
        refresh()
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        controller.updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func checkForUpdates() {
        guard canCheck, !AppModel.shared.busy else { return }
        controller.checkForUpdates(nil)
    }

    private func refresh() {
        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        automaticUpdates = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        phase = .checking
        status = "正在检查更新…"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        phase = .available
        status = "发现新版本 \(item.displayVersionString)"
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        phase = .downloading
        status = "正在下载 \(item.displayVersionString)"
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        phase = .verifying
        status = "正在校验并准备更新"
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        phase = .ready
        status = "新版已就绪，可以安装更新"
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        phase = .available
        status = "已取消下载，可再次检查更新"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        phase = .ready
        status = "新版已就绪，退出轻压时自动安装"
        return false
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard AppModel.shared.busy else { return false }
        deferredInstall = installHandler
        phase = .deferred
        status = "任务完成后安装更新"
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
                let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value ?? SPUNoUpdateFoundReason.unknown.rawValue
                if reason == SPUNoUpdateFoundReason.systemIsTooOld.rawValue || reason == SPUNoUpdateFoundReason.systemIsTooNew.rawValue || reason == SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue {
                    phase = .incompatible
                    status = "新版不支持当前系统或硬件"
                } else if reason == SPUNoUpdateFoundReason.onLatestVersion.rawValue || reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue {
                    phase = .current
                    status = "已是最新版本"
                } else {
                    phase = .noUpdate
                    status = "未发现适用于当前系统的新版本"
                }
            } else if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue {
                phase = .available
                status = "已取消安装，可再次检查更新"
            } else {
                phase = .failed
                status = "更新未完成：\(error.localizedDescription)"
            }
        } else if phase == .checking {
            phase = .unchecked
            status = "检查已取消"
        }
        refresh()
    }
}
