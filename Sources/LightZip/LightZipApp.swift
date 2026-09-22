import SwiftUI
import AppKit
import ArchiveCore
import FinderBridge

@main struct LightZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var updater = AppUpdater.shared
    var body: some Scene {
        Window("轻压", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于轻压") { NSApp.orderFrontStandardAboutPanel(nil) }
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck || model.busy)
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出轻压") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置") { model.showInformationPage(.settings) }
                    .keyboardShortcut(",").disabled(model.busy)
            }
            CommandGroup(replacing: .newItem) {
                Button("打开压缩包…") { model.switchMode(.extract); model.chooseFiles() }.keyboardShortcut("o").disabled(model.busy)
                Button("创建压缩包…") { model.switchMode(.compress); model.chooseFiles() }.keyboardShortcut("n").disabled(model.busy)
            }
            CommandGroup(replacing: .help) {
                Button("轻压使用说明") { model.showInformationPage(.help) }.disabled(model.busy)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let finderServices = FinderServices()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = finderServices
        NSUpdateDynamicServices()
        AppUpdater.shared.start()
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let tickets = urls.filter { $0.scheme == "lightzip" }
        if !tickets.isEmpty {
            do {
                guard tickets.count == 1, urls.count == 1 else { throw FinderRequestError.invalid }
                let request = try FinderRequestStore.hostStore().consume(tickets[0])
                guard !AppModel.shared.busy else { throw ArchiveFailure.message("轻压正在处理任务，完成后请重新右键选择。") }
                let operation: FinderOperation = request.action == .extract ? .extract : .compress
                let selection = try FinderSelection(operation: operation, files: request.files)
                AppModel.shared.receiveService(selection)
            } catch {
                AppModel.shared.notice = error.localizedDescription
            }
        } else {
            AppModel.shared.receive(urls, openedFromFinder: true)
        }
        application.activate(ignoringOtherApps: true)
        application.windows.first?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppModel.shared.isOpeningArchive || AppModel.shared.recoveryRunning {
            Task {
                await AppModel.shared.cancelAndWait()
                sender.reply(toApplicationShouldTerminate: cleanupBeforeQuit())
            }
            return .terminateLater
        }
        if AppModel.shared.busy {
            let alert = NSAlert()
            alert.messageText = "任务仍在进行"
            alert.informativeText = "请先取消当前任务，再退出轻压。"
            alert.addButton(withTitle: "继续任务")
            alert.addButton(withTitle: "取消任务")
            if alert.runModal() == .alertSecondButtonReturn { AppModel.shared.cancel() }
            return .terminateCancel
        }
        return cleanupBeforeQuit() ? .terminateNow : .terminateCancel
    }

    private func cleanupBeforeQuit() -> Bool {
        guard AppModel.shared.cleanupWorkspaces() else {
            let alert = NSAlert()
            alert.messageText = "临时文件未能清理"
            alert.informativeText = AppModel.shared.notice ?? "请关闭正在使用临时文件的应用后重试。"
            alert.addButton(withTitle: "返回轻压")
            alert.runModal()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.cleanupWorkspaces()
    }
}
