import AppKit
import ArchiveCore

@MainActor final class FinderServices: NSObject {
    @objc func extractArchive(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard, operation: .extract, error: error)
    }

    @objc func compressFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pasteboard, operation: .compress, error: error)
    }

    private func handle(_ pasteboard: NSPasteboard, operation: FinderOperation, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
                urls = paths.map { URL(fileURLWithPath: $0) }
            }
            let selection = try FinderSelection(operation: operation, files: urls)
            guard !AppModel.shared.busy else { throw ArchiveFailure.message("轻压正在处理任务，请完成或取消后再使用右键服务。") }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            AppModel.shared.receiveService(selection)
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }
}
