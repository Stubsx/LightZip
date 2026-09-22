import AppKit
import SwiftUI
import ArchiveCore

enum WorkspaceMode: String, CaseIterable {
    case extract = "打开压缩包"
    case compress = "创建压缩包"
    case history = "最近任务"
    var symbol: String {
        switch self { case .extract: return "archivebox"; case .compress: return "shippingbox"; case .history: return "clock.arrow.circlepath" }
    }
}

enum InformationPage: String {
    case settings = "设置"
    case help = "使用说明"
}

struct JobRecord: Identifiable {
    let id = UUID()
    let name: String
    let operation: String
    let date: Date
    let output: URL?
    let detail: String
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var mode: WorkspaceMode = .extract
    @Published var informationPage: InformationPage?
    @Published var files: [URL] = []
    @Published var workspace: TemporaryArchive?
    @Published var directoryComponents: [String] = []
    @Published var items: [WorkspaceItem] = []
    @Published var selectedItemID: String?
    @Published var isOpeningArchive = false
    @Published var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @Published var archiveName = "归档"
    @Published var format = "zip"
    @Published var level = 5
    @Published var password = ""
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var status = "就绪"
    @Published var notice: String?
    @Published var result: URL?
    @Published var records: [JobRecord] = []
    @Published var search = ""
    @Published var showingPassword = false
    @Published var passwordMessage = "输入密码后继续。"
    @Published var previewURL: URL?
    @Published var showingRecovery = false
    @Published var recoveryRunning = false
    @Published var recoveryProgress = RecoveryProgress(message: "选择候选范围，开始找回密码。")
    @Published var recoveredPassword: String?
    @Published var recoveryMessage: String?
    private var recovery: PasswordRecovery?
    private var recoverAfterPasswordDismiss = false
    private var retryAfterRecoveryDismiss = false
    private var engine: ArchiveEngine?
    private var task: Task<Void, Never>?
    // A nested archive can still be backed by its parent's temporary files.
    // Keep those owners alive until the nested archive is closed as well.
    private var sessions: [TemporaryArchive] = []
    private var directExtraction = false
    private var pendingExtraction = false
    private var retryAfterPassword = false
    private enum FileAction { case open, preview }
    private var pendingAccess: (WorkspaceItem, FileAction)?

    var executable: URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/7zip/7zz")
    }
    var filteredItems: [WorkspaceItem] { search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) } }
    var selectedItem: WorkspaceItem? { filteredItems.first { $0.id == selectedItemID } }
    var canStart: Bool { !busy && !files.isEmpty && (mode != .compress || !archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }

    func switchMode(_ newMode: WorkspaceMode) {
        guard !busy else { return }
        if mode != newMode && newMode != .history && !reset() { return }
        mode = newMode
        informationPage = nil
    }

    @discardableResult func reset() -> Bool {
        guard !busy, cleanupWorkspaces() else { return false }
        files = []; password = ""; notice = nil; result = nil; search = ""; status = "就绪"; progress = 0
        directExtraction = false
        pendingExtraction = false; showingPassword = false; retryAfterPassword = false
        showingRecovery = false; recoveredPassword = nil; recoveryMessage = nil
        recoverAfterPasswordDismiss = false; retryAfterRecoveryDismiss = false
        return true
    }

    @discardableResult func cleanupWorkspaces() -> Bool {
        previewURL = nil
        pendingAccess = nil
        do {
            for session in sessions.reversed() { try session.close() }
            sessions = []; workspace = nil; items = []; directoryComponents = []; selectedItemID = nil
            return true
        } catch {
            notice = "临时文件未能清理：\(error.localizedDescription)"
            return false
        }
    }

    func chooseFiles() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = mode == .compress
        panel.allowsMultipleSelection = mode == .compress
        panel.title = mode == .compress ? "选择要压缩的文件或文件夹" : "选择压缩包"
        panel.prompt = "选择"
        if panel.runModal() == .OK { receive(panel.urls) }
    }

    func receive(_ urls: [URL], openedFromFinder: Bool = false, autoExtract: Bool = false) {
        guard !busy else { notice = "当前任务正在进行，完成后可打开其他文件。"; return }
        guard !urls.isEmpty else { return }
        let incomingMode: WorkspaceMode = openedFromFinder || informationPage != nil || mode == .history ? .extract : mode
        if incomingMode == .extract {
            guard urls.count == 1 else { notice = "每次打开一个压缩包，请选择其中一个。"; return }
            // Validate a nested file before handing it to the extraction engine.
            if let owner = sessions.first(where: { $0.contains(urls[0]) }), let components = owner.components(for: urls[0]) {
                do { _ = try owner.checkedURL(for: components) }
                catch { notice = error.localizedDescription; return }
                previewURL = nil; pendingAccess = nil
                workspace = nil; items = []; directoryComponents = []; selectedItemID = nil; files = []
            } else if !reset() { return }
            mode = .extract
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &directory), directory.boolValue {
                mode = .compress
            }
        }
        informationPage = nil
        notice = nil; result = nil; status = "就绪"
        if mode == .extract {
            files = [urls[0]]; password = ""; search = ""
            if !sessions.contains(where: { $0.contains(urls[0]) }) { destination = urls[0].deletingLastPathComponent() }
            directExtraction = autoExtract
            if autoExtract { start() } else { openContents() }
        } else {
            if files.isEmpty {
                destination = urls[0].deletingLastPathComponent()
                let isDirectory = (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                archiveName = urls.count == 1 ? (isDirectory ? urls[0].lastPathComponent : urls[0].deletingPathExtension().lastPathComponent) : "归档"
            }
            for url in urls where !files.contains(url) { files.append(url) }
        }
    }

    @discardableResult func chooseDestination() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = destination; panel.title = "选择保存位置"; panel.prompt = "保存到这里"
        if panel.runModal() == .OK, let url = panel.url { destination = url; return true }
        return false
    }

    func extractAll() {
        guard canStart, mode == .extract, chooseDestination() else { return }
        start()
    }

    func requestPassword() {
        passwordMessage = "输入密码后继续。"
        showingPassword = true
    }

    func confirmPassword() {
        retryAfterPassword = true
        showingPassword = false
    }

    func passwordSheetDidDismiss() {
        if recoverAfterPasswordDismiss {
            recoverAfterPasswordDismiss = false
            showingRecovery = true
            return
        }
        guard retryAfterPassword else { return }
        retryAfterPassword = false
        retryOpen()
    }

    func requestRecovery() {
        guard !busy, mode == .extract, !files.isEmpty else { return }
        recoveredPassword = nil; recoveryMessage = nil
        recoveryProgress = RecoveryProgress(message: "选择候选范围，开始找回密码。")
        previewURL = nil
        if showingPassword { recoverAfterPasswordDismiss = true; showingPassword = false }
        else { showingRecovery = true }
    }

    func startRecovery(_ method: RecoveryMethod) {
        guard !busy, let archive = files.first else { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Recovery")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Vendor/recovery")
        let directory = FileManager.default.fileExists(atPath: bundled.path) ? bundled : source
        let recovery = PasswordRecovery(toolsDirectory: directory, archiveEngine: ArchiveEngine(executable: executable))
        self.recovery = recovery; recoveryRunning = true; busy = true
        recoveredPassword = nil; recoveryMessage = nil; notice = nil
        recoveryProgress = RecoveryProgress(message: "正在准备密码找回…")
        status = "正在找回密码…"; progress = 0
        task = Task {
            do {
                let found = try await Task.detached(priority: .utility) {
                    try recovery.recover(archive, method: method) { update in
                        Task { @MainActor in
                            guard self.recoveryRunning, self.recovery === recovery else { return }
                            self.recoveryProgress = update
                        }
                    }
                }.value
                recoveredPassword = found
                if found != nil { recoveryMessage = "密码已确认，可以继续打开。" }
                else if case .dictionary = method { recoveryMessage = "这份字典中没有找到密码，可以更换字典或规则。" }
                else { recoveryMessage = "已检查完所选范围，没有找到密码。可以增加位数或更换密码类型。" }
                status = found == nil ? "本次未找到密码" : "已找到密码"
            } catch is CancellationError {
                recoveryMessage = "已停止，可以调整范围后重新开始。"; status = "已停止密码找回"
            } catch { recoveryMessage = error.localizedDescription; status = "密码找回未完成" }
            recoveryRunning = false; busy = false; self.recovery = nil
        }
    }

    func useRecoveredPassword() {
        guard !recoveryRunning, let found = recoveredPassword else { return }
        password = found; retryAfterRecoveryDismiss = true; showingRecovery = false
    }

    func recoverySheetDidDismiss() {
        recoveredPassword = nil; recoveryMessage = nil
        guard retryAfterRecoveryDismiss else { return }
        retryAfterRecoveryDismiss = false
        retryOpen()
    }

    private func handleFailure(_ error: Error) {
        if case ArchiveFailure.passwordRequired = error {
            passwordMessage = password.isEmpty ? "这个压缩包已加密，请输入密码。" : "密码不正确，请重新输入。"
            showingPassword = true
            notice = nil
        } else { notice = error.localizedDescription }
    }

    func retryOpen() {
        if let (item, action) = pendingAccess { accessFile(item, action: action) }
        else if pendingExtraction || directExtraction { start() }
        else { openContents() }
    }

    func openContents() {
        guard !busy, workspace == nil, let archive = files.first else { return }
        let engine = ArchiveEngine(executable: executable)
        self.engine = engine; busy = true; isOpeningArchive = true; progress = 0
        status = "正在读取压缩包目录…"; notice = nil
        let password = password
        task = Task {
            do {
                let session = try await Task.detached(priority: .userInitiated) {
                    try TemporaryArchive.open(archive, engine: engine, password: password)
                }.value
                sessions.append(session); workspace = session
                navigate(to: [])
                status = "目录已读取，文件按需解压"; progress = 1
            } catch is CancellationError { status = "已取消"; progress = 0 }
            catch { handleFailure(error); status = "暂时无法打开" }
            busy = false; isOpeningArchive = false; self.engine = nil
        }
    }

    func navigate(to components: [String]) {
        guard let workspace else { return }
        do {
            let children = try workspace.items(in: components)
            previewURL = nil; pendingAccess = nil
            directoryComponents = components; items = children; search = ""; selectedItemID = nil; notice = nil
        } catch { notice = error.localizedDescription }
    }

    func refreshDirectory() {
        guard !busy, let workspace else { return }
        do { items = try workspace.items(in: directoryComponents) }
        catch { notice = error.localizedDescription }
    }

    func openItem(_ item: WorkspaceItem) {
        guard !busy, workspace != nil else { return }
        if item.isDirectory { navigate(to: item.components) }
        else { accessFile(item, action: .open) }
    }

    func openSelectedItem() {
        if let item = selectedItem { openItem(item) }
    }

    func previewSelectedItem() {
        if previewURL != nil { previewURL = nil; return }
        if let item = selectedItem { previewItem(item) }
    }

    func previewItem(_ item: WorkspaceItem) {
        guard !item.isDirectory else { return }
        accessFile(item, action: .preview)
    }

    private func accessFile(_ item: WorkspaceItem, action: FileAction) {
        guard !busy, let workspace else { return }
        let engine = ArchiveEngine(executable: executable)
        self.engine = engine; busy = true; isOpeningArchive = true; progress = 0; notice = nil
        status = "正在准备「\(item.name)」…"
        pendingAccess = (item, action)
        let password = password
        task = Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try workspace.materialize(item.components, engine: engine, password: password) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }.value
                // Release the busy guard before LaunchServices delivers a nested
                // archive back to this app through application(_:open:).
                busy = false; isOpeningArchive = false; self.engine = nil; pendingAccess = nil
                progress = 1; status = action == .preview ? "已准备快速查看" : "已打开文件"
                if action == .preview { previewURL = url }
                else if !NSWorkspace.shared.open(url) { notice = "无法打开这个文件，请检查是否已安装对应应用。" }
                return
            } catch is CancellationError {
                status = "已取消"; progress = 0; pendingAccess = nil
            } catch {
                handleFailure(error); status = "暂时无法打开文件"
            }
            busy = false; isOpeningArchive = false; self.engine = nil
        }
    }

    func receiveService(_ selection: FinderSelection) {
        guard !busy else { return }
        guard reset() else { return }
        mode = selection.operation == .extract ? .extract : .compress
        informationPage = nil
        receive(selection.files, autoExtract: selection.operation == .extract)
    }

    func removeFile(_ file: URL) {
        guard !busy else { return }
        files.removeAll { $0 == file }
        result = nil; notice = nil; status = "就绪"
    }

    func start() {
        guard canStart else { return }
        pendingExtraction = mode == .extract
        let engine = ArchiveEngine(executable: executable)
        self.engine = engine; busy = true; notice = nil; result = nil; progress = 0
        let mode = mode, inputs = files, parent = destination, name = archiveName
        let format = format, level = level, password = password
        status = mode == .extract ? "正在检查并解压…" : "正在压缩…"
        task = Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    let callback: @Sendable (Double) -> Void = { value in
                        Task { @MainActor in self.progress = value }
                    }
                    if mode == .extract { return try engine.extract(inputs[0], into: parent, password: password, progress: callback) }
                    return try engine.compress(inputs, into: parent, name: name, format: format, level: level, password: password, progress: callback)
                }.value
                pendingExtraction = false; directExtraction = false
                result = output; progress = 1; status = mode == .extract ? "解压完成" : "压缩完成"
                records.insert(JobRecord(name: output.lastPathComponent, operation: mode == .extract ? "解压文件" : mode.rawValue, date: Date(), output: output, detail: "完成"), at: 0)
            } catch is CancellationError {
                status = "已取消"; progress = 0; pendingExtraction = false
            } catch {
                status = "任务未完成"; handleFailure(error)
                records.insert(JobRecord(name: inputs.first?.lastPathComponent ?? name, operation: mode.rawValue, date: Date(), output: nil, detail: error.localizedDescription), at: 0)
            }
            if records.count > 30 { records = Array(records.prefix(30)) }
            busy = false; self.engine = nil
        }
    }

    func cancel() {
        status = "正在取消…"; engine?.cancel(); recovery?.cancel()
        if recoveryRunning { recoveryProgress.message = "正在停止并清理…" }
    }
    func cancelAndWait() async { cancel(); await task?.value }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func showInformationPage(_ page: InformationPage) {
        guard !busy else { return }
        previewURL = nil
        informationPage = page
    }
}
