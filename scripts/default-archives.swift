// Explicit, user-requested file associations. Ordinary installs do not change them.
import AppKit
import UniformTypeIdentifiers

let app = URL(fileURLWithPath: "/Applications/轻压.app")
let archiveExtensions = ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "lzma", "tgz", "tbz2", "txz"]
let setting = CommandLine.arguments.dropFirst().contains("--set")
var seen = Set<String>()
let types = archiveExtensions.compactMap { UTType(filenameExtension: $0) }
    .filter { !$0.isDynamic && seen.insert($0.identifier).inserted }

Task { @MainActor in
    do {
        guard Bundle(url: app)?.bundleIdentifier == "local.lightzip.app" else {
            throw NSError(domain: "LightZip", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先安装轻压。"])
        }
        if setting {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".backups/default-apps-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let previous = types.map { type -> [String: String] in
                let previousApp = NSWorkspace.shared.urlForApplication(toOpen: type)
                return ["type": type.identifier, "application": previousApp?.path ?? "",
                        "bundleIdentifier": previousApp.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""]
            }
            try JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("previous-handlers.json"))
            print("原默认打开方式已记录：\(directory.path)")
            for type in types {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            }
        }
        var allMatched = true
        for type in types {
            let handler = NSWorkspace.shared.urlForApplication(toOpen: type)
            let matches = handler?.standardizedFileURL.resolvingSymlinksInPath() == app.resolvingSymlinksInPath()
            allMatched = allMatched && matches
            print("\(type.identifier) → \(handler?.path ?? "未设置")")
        }
        if setting && !allMatched {
            throw NSError(domain: "LightZip", code: 2, userInfo: [NSLocalizedDescriptionKey: "部分文件关联未生效，请检查上述结果。"])
        }
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
