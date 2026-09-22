import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class DefaultArchiveApplication: ObservableObject {
    @Published private(set) var isSetting = false
    @Published var showingResult = false
    @Published private(set) var resultMessage = ""

    // Use concrete archive types, never the broad public.archive or public.data
    // parent types (which would also affect unrelated documents).
    private let extensions = ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "lzma", "tgz", "tbz2", "txz"]

    func setAsDefault() {
        guard !isSetting else { return }
        let application = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard application.pathExtension == "app", Bundle.main.bundleIdentifier == "local.lightzip.app" else {
            resultMessage = "请先安装并打开轻压，再设置默认打开应用。"
            showingResult = true
            return
        }
        isSetting = true
        Task {
            var failed: [String] = []
            var seen = Set<String>()
            for ext in extensions {
                guard let type = UTType(filenameExtension: ext), !type.isDynamic else {
                    failed.append(ext.uppercased())
                    continue
                }
                guard seen.insert(type.identifier).inserted else { continue }
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type)
                    let selected = NSWorkspace.shared.urlForApplication(toOpen: type)?.resolvingSymlinksInPath()
                    if selected != application { failed.append(ext.uppercased()) }
                } catch {
                    failed.append(ext.uppercased())
                }
            }
            isSetting = false
            if failed.isEmpty {
                resultMessage = "已设为默认打开应用。\n双击 ZIP、7Z、RAR 等压缩包，即可用轻压查看内容。"
            } else {
                resultMessage = "以下格式未设置成功：\(failed.joined(separator: "、"))。\n请重试，或在访达的“显示简介 → 打开方式”中设置。"
            }
            showingResult = true
        }
    }
}
