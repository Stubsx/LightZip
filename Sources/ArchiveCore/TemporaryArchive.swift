import Foundation
import Darwin

public struct WorkspaceItem: Identifiable, Sendable {
    public let components: [String]
    public let name: String
    public let size: Int64?
    public let isDirectory: Bool
    public let isEncrypted: Bool
    public var id: String { components.joined(separator: "/") }
}

/// Immutable archive index plus lazily materialized files. The caller serializes
/// materialization and closing; browsing never reads or extracts file payloads.
public final class TemporaryArchive: @unchecked Sendable {
    public let directory: URL
    public let isSolid: Bool
    public let hasEncryptedFiles: Bool
    private let storage: URL
    private let archive: URL
    private let fingerprint: Fingerprint
    private let singleStream: Bool
    private let children: [String: [WorkspaceItem]]
    private let members: [String: ArchiveEntry]
    private var cachedFiles: [String: URL] = [:]

    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
        init(_ url: URL) throws {
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw ArchiveFailure.message("压缩包已移动或无法读取，请重新打开。")
            }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            seconds = info.st_mtimespec.tv_sec; nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private init(archive: URL, storage: URL, catalog: ArchiveCatalog, fingerprint: Fingerprint) {
        self.archive = archive; self.storage = storage; directory = storage
        self.fingerprint = fingerprint; singleStream = catalog.isSingleStream
        isSolid = catalog.isSolid; hasEncryptedFiles = catalog.entries.contains { $0.isEncrypted }
        var nodes: [String: WorkspaceItem] = [:]
        var members: [String: ArchiveEntry] = [:]
        for entry in catalog.entries {
            let parts = entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }.map(String.init)
            for length in 1...parts.count {
                let components = Array(parts.prefix(length))
                let id = components.joined(separator: "/")
                let isLeaf = length == parts.count
                if isLeaf || nodes[id] == nil {
                    nodes[id] = WorkspaceItem(components: components, name: components.last!,
                                              size: isLeaf && entry.sizeIsKnown ? entry.size : nil,
                                              isDirectory: !isLeaf || entry.isDirectory,
                                              isEncrypted: isLeaf && entry.isEncrypted)
                }
                if isLeaf && !entry.isDirectory { members[id] = entry }
            }
        }
        self.members = members
        children = Dictionary(grouping: nodes.values) { $0.components.dropLast().joined(separator: "/") }
            .mapValues { items in
                items.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
    }

    public static func open(_ archive: URL, engine: ArchiveEngine, password: String = "",
                            temporaryParent: URL = FileManager.default.temporaryDirectory) throws -> TemporaryArchive {
        let source = archive.resolvingSymlinksInPath()
        let fingerprint = try Fingerprint(source)
        let catalog = try engine.catalog(source, password: password)
        guard try fingerprint == Fingerprint(source) else {
            throw ArchiveFailure.message("压缩包已改变，请重新打开。")
        }
        let storage = temporaryParent.appendingPathComponent("lightzip-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return TemporaryArchive(archive: source, storage: storage, catalog: catalog, fingerprint: fingerprint)
    }

    public func items(in components: [String] = []) throws -> [WorkspaceItem] {
        let key = try Self.key(components)
        guard key.isEmpty || children[components.dropLast().joined(separator: "/")]?.contains(where: { $0.id == key && $0.isDirectory }) == true else {
            throw ArchiveFailure.message("压缩包中没有这个文件夹。")
        }
        return children[key] ?? []
    }

    /// Extract at most one file; repeated previews and opens reuse that same copy,
    /// including edits made to it. A failed request never enters the cache.
    public func materialize(_ components: [String], engine: ArchiveEngine, password: String = "",
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> URL {
        let key = try Self.key(components)
        guard let entry = members[key] else { throw ArchiveFailure.message("请选择压缩包内的文件。") }
        guard try fingerprint == Fingerprint(archive) else {
            throw ArchiveFailure.message("原压缩包已改变，请关闭后重新打开。")
        }
        if let cached = cachedFiles[key] {
            if FileManager.default.fileExists(atPath: cached.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: cached.path)) != nil {
                return try checkedURL(for: components)
            }
            cachedFiles.removeValue(forKey: key)
        }
        let file = try engine.extractMember(archive, entry: entry, singleStream: singleStream, into: storage,
                                            password: password, progress: progress)
        do {
            guard try fingerprint == Fingerprint(archive) else {
                throw ArchiveFailure.message("原压缩包已改变，请关闭后重新打开。")
            }
        } catch {
            try? Self.removeStorage(file.deletingLastPathComponent())
            throw error
        }
        cachedFiles[key] = file
        return try checkedURL(for: components)
    }

    public func contains(_ url: URL) -> Bool { components(for: url) != nil }

    public func components(for url: URL) -> [String]? {
        let path = url.standardizedFileURL.path
        // Match both macOS spellings of the temp directory, without resolving
        // the cached file itself (which an external editor may replace with a link).
        for (key, file) in cachedFiles {
            let canonicalParent = file.deletingLastPathComponent().resolvingSymlinksInPath()
            if path == file.standardizedFileURL.path || path == canonicalParent.appendingPathComponent(file.lastPathComponent).path {
                return key.split(separator: "/").map(String.init)
            }
        }
        return nil
    }

    public func checkedURL(for components: [String]) throws -> URL {
        let key = try Self.key(components)
        guard let file = cachedFiles[key] else { throw ArchiveFailure.message("这个文件尚未解压。") }
        let root = storage.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(root + "/") else { throw ArchiveFailure.message("无法打开临时目录之外的文件。") }
        var current = storage
        let relative = filePath.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        for part in [""] + relative {
            if !part.isEmpty { current.appendPathComponent(part) }
            let values = try URL(fileURLWithPath: current.path).resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw ArchiveFailure.message("临时文件已变为链接或特殊文件，无法打开。")
            }
        }
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ArchiveFailure.message("临时文件已改变，请关闭压缩包后重试。")
        }
        return file
    }

    private static func key(_ components: [String]) throws -> String {
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            throw ArchiveFailure.message("无法打开临时目录之外的文件。")
        }
        return components.joined(separator: "/")
    }

    public func close() throws {
        if FileManager.default.fileExists(atPath: storage.path) {
            try Self.removeStorage(storage)
        }
    }

    private static func removeStorage(_ storage: URL) throws {
        do { try FileManager.default.removeItem(at: storage) }
        catch {
            // Archives may carry read-only directory modes. Repair only this
            // session's directories; descriptor-relative traversal never follows
            // links inserted by an external application while files were open.
            let descriptor = Darwin.open(storage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw error }
            defer { Darwin.close(descriptor) }
            try makeDirectoriesWritable(descriptor)
            try FileManager.default.removeItem(at: storage)
        }
    }

    private static func makeDirectoriesWritable(_ descriptor: Int32) throws {
        func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard fchmod(descriptor, 0o700) == 0 else { throw posixError() }
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw posixError() }
        guard let stream = fdopendir(duplicate) else {
            let error = posixError(); Darwin.close(duplicate); throw error
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard fchmodat(descriptor, name, 0o700, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
            let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { throw posixError() }
            defer { Darwin.close(child) }
            try makeDirectoriesWritable(child)
        }
    }

    deinit { try? close() }
}
