import AppKit
import FinderSync
import os

final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "local.lightzip.app", category: "FinderExtension")
    // Finder copies menu items across processes; tags survive, representedObject does not.
    private var requests: [Int: FinderRequest] = [:]
    private var nextTag = 0

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(),
              let action = FinderAction.forSelection(urls, isDirectory: {
                  (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
              }) else { return nil }
        nextTag += 1
        requests[nextTag] = FinderRequest(action: action, files: urls)
        requests.removeValue(forKey: nextTag - 512)
        let menu = NSMenu(title: "轻压")
        let item = NSMenuItem(title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = nextTag
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let selection = requests[sender.tag] else { return }
        do {
            let request = FinderRequest(action: selection.action, files: selection.files)
            let url = try FinderRequestStore.extensionStore().enqueue(request)
            let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open([url], withApplicationAt: host, configuration: configuration) { [logger] _, error in
                if let error { logger.error("Host launch failed: \(error.localizedDescription, privacy: .public)") }
            }
        } catch {
            logger.error("Finder request failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
