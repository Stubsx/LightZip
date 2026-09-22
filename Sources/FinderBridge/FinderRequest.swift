import Foundation

public enum FinderAction: String, Codable, Sendable {
    case extract, compress

    public var title: String { self == .extract ? "用轻压解压" : "用轻压压缩…" }
    public var symbol: String { self == .extract ? "archivebox" : "shippingbox" }

    public static func forSelection(_ urls: [URL], isDirectory: (URL) -> Bool) -> FinderAction? {
        guard !urls.isEmpty, urls.count <= FinderRequest.maximumItems, urls.allSatisfy(\.isFileURL) else { return nil }
        let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "tgz", "tbz", "tbz2", "txz"]
        if urls.count == 1, !isDirectory(urls[0]) {
            let name = urls[0].lastPathComponent.lowercased()
            if archiveExtensions.contains(urls[0].pathExtension.lowercased()) || name.hasSuffix(".zip.001") || name.hasSuffix(".7z.001") {
                return .extract
            }
        }
        return .compress
    }
}

public struct FinderRequest: Codable, Sendable {
    public static let maximumItems = 4096
    public let action: FinderAction
    public let files: [URL]
    public let createdAt: Date

    public init(action: FinderAction, files: [URL], createdAt: Date = Date()) {
        self.action = action
        self.files = files
        self.createdAt = createdAt
    }
}

public enum FinderRequestError: LocalizedError {
    case invalid, expired
    public var errorDescription: String? {
        switch self {
        case .invalid: return "无法读取这次右键操作，请在访达中重新选择文件。"
        case .expired: return "这次右键操作已过期，请重新右键选择。"
        }
    }
}

/// The URL carries only a random, one-use ticket. File paths and the action are
/// read from the Finder extension's private container, never from a web link.
public struct FinderRequestStore {
    public static let extensionIdentifier = "local.lightzip.app.finder"
    public let directory: URL
    private static let maximumBytes = 2 * 1024 * 1024

    public init(directory: URL) { self.directory = directory }

    public static func extensionStore() throws -> FinderRequestStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return FinderRequestStore(directory: support.appendingPathComponent("LightZip/FinderRequests", isDirectory: true))
    }

    public static func hostStore() -> FinderRequestStore {
        FinderRequestStore(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionIdentifier)/Data/Library/Application Support/LightZip/FinderRequests", isDirectory: true))
    }

    public func enqueue(_ request: FinderRequest) throws -> URL {
        try validate(request)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(request)
        guard data.count <= Self.maximumBytes else { throw FinderRequestError.invalid }
        // Clear only old tickets owned by this queue; abandoned clicks should
        // not leave a permanent history of selected paths.
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
               let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) > 300 {
                try? manager.removeItem(at: file)
            }
        }
        let ticket = UUID().uuidString
        let file = directory.appendingPathComponent(ticket + ".json")
        try data.write(to: file, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return URL(string: "lightzip://finder/\(ticket)")!
    }

    public func consume(_ url: URL) throws -> FinderRequest {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "lightzip", parts.host == "finder", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              let ticket = UUID(uuidString: String(parts.path.dropFirst())),
              parts.path == "/" + ticket.uuidString else { throw FinderRequestError.invalid }
        let file = directory.appendingPathComponent(ticket.uuidString + ".json")
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size <= Self.maximumBytes else { throw FinderRequestError.invalid }
        let data = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let request = try JSONDecoder().decode(FinderRequest.self, from: data)
        try validate(request)
        let age = Date().timeIntervalSince(request.createdAt)
        guard age >= -5, age < 120 else { throw FinderRequestError.expired }
        return request
    }

    private func validate(_ request: FinderRequest) throws {
        guard !request.files.isEmpty, request.files.count <= FinderRequest.maximumItems,
              request.files.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") }),
              request.action != .extract || request.files.count == 1 else { throw FinderRequestError.invalid }
    }
}
