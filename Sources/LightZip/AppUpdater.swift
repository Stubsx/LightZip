import AppKit
import Combine
import Sparkle

/// Sparkle owns download, signature verification and atomic app replacement.
/// The app keeps its existing termination/temporary-file cleanup lifecycle.
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var automaticUpdates = true
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var status = ""

    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var busyObservation: AnyCancellable?
    private var deferredInstall: (() -> Void)?
    private var started = false

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
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
        status = "正在检查更新…"
        controller.checkForUpdates(nil)
    }

    private func refresh() {
        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        automaticUpdates = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "发现新版本 \(item.displayVersionString)"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        status = "新版已就绪，退出轻压时自动安装"
        return false
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard AppModel.shared.busy else { return false }
        deferredInstall = installHandler
        status = "任务完成后安装更新"
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
                status = "已是最新版本"
            } else {
                status = "更新未完成：\(error.localizedDescription)"
            }
        }
        refresh()
    }
}
