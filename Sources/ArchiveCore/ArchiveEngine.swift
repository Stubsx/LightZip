import Foundation
import Darwin

public struct ArchiveEntry: Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    public let isEncrypted: Bool
    public var sizeIsKnown = true
}

public struct ArchiveCatalog: Sendable {
    public let entries: [ArchiveEntry]
    public let isSolid: Bool
    public let isSingleStream: Bool
}

public enum ArchiveFailure: LocalizedError {
    case message(String)
    case passwordRequired
    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .passwordRequired: return "压缩包需要密码，或输入的密码不正确。请填写密码后重试。"
        }
    }
}

/// One instance per job. The cancellation flag also covers the gaps between subprocesses.
public final class ArchiveEngine: @unchecked Sendable {
    public let executable: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init(executable: URL) { self.executable = executable }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning {
            running.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if running.isRunning { running.terminate() }
            }
        }
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    private func run(_ arguments: [String], password: String = "", directory: URL? = nil,
                     writeRoot: URL? = nil, captureLimit: Int = 64 * 1024 * 1024,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> String {
        try checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ArchiveFailure.message("压缩引擎缺失，请重新构建或安装轻压。")
        }
        guard !password.contains("\n"), !password.contains("\r"), password.utf8.count <= 1024 else {
            throw ArchiveFailure.message("密码不能包含换行，且长度不能超过 1024 字节。")
        }
        let task = Process()
        if let writeRoot {
            // Constrain extraction writes even if an archive has misleading paths or links.
            guard let canonical = realpath(writeRoot.path, nil) else { throw ArchiveFailure.message("无法确认解压目录。") }
            let canonicalPath = String(cString: canonical)
            free(canonical)
            let root = canonicalPath
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            task.arguments = ["-p", "(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (subpath \"\(root)\") (literal \"/dev/null\"))", executable.path] + arguments
        } else {
            task.executableURL = executable
            task.arguments = arguments
        }
        task.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        task.environment = environment
        let output = Pipe()
        // A small regular input file avoids SIGPIPE and never exposes passwords in argv.
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("lightzip-input-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: inputURL.path,
            contents: Data((password + "\n" + password + "\n").utf8),
            attributes: [.posixPermissions: 0o600]) else {
            throw ArchiveFailure.message("无法建立任务输入。")
        }
        let input = try FileHandle(forReadingFrom: inputURL)
        try FileManager.default.removeItem(at: inputURL) // Unlink before launching the process.
        defer { try? input.close() }
        task.standardInput = input
        task.standardOutput = output
        task.standardError = output
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer { lock.lock(); process = nil; lock.unlock() }
        var data = Data()
        var overflow = false
        var tail = ""
        let expression = try! NSRegularExpression(pattern: "(?:^|[^0-9])([0-9]{1,3})%")
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count + chunk.count <= captureLimit { data.append(chunk) }
            else if !overflow { overflow = true; task.terminate() }
            let text = tail + String(decoding: chunk, as: UTF8.self)
            if let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range(at: 1), in: text), let percent = Double(text[range]) {
                progress(min(1, percent / 100))
            }
            tail = String(text.suffix(12))
        }
        task.waitUntilExit()
        try checkCancellation()
        if overflow { throw ArchiveFailure.message("压缩包目录过大，超出当前版本的处理上限。") }
        let result = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{08}", with: "")
        guard task.terminationStatus == 0 else {
            let lower = result.lowercased()
            if lower.contains("wrong password") || lower.contains("password is incorrect") || lower.contains("encrypted archive") || (password.isEmpty && lower.contains("enter password")) {
                throw ArchiveFailure.passwordRequired
            }
            if lower.contains("no space left") { throw ArchiveFailure.message("目标磁盘空间不足，请更换保存位置。") }
            if lower.contains("missing volume") { throw ArchiveFailure.message("缺少分卷。请把所有分卷放在同一目录，并打开第一卷。") }
            if lower.contains("permission denied") || lower.contains("access is denied") || lower.contains("operation not permitted") {
                throw ArchiveFailure.message("无法访问文件或保存位置，请检查文件权限，或选择其他保存位置。")
            }
            if lower.contains("unexpected end") || lower.contains("crc failed") || lower.contains("data error") || lower.contains("headers error") {
                throw ArchiveFailure.message("压缩包内容损坏或不完整，请确认文件已完整下载；分卷压缩包需放齐所有分卷。")
            }
            throw ArchiveFailure.message("任务未完成：压缩包损坏、格式不支持或文件无法访问。请检查文件并重试。")
        }
        return result
    }

    public func verifyRecoveredPassword(_ archive: URL, password: String) throws {
        let entries = try list(archive, password: password)
        guard let entry = entries.filter({ $0.isEncrypted && !$0.isDirectory }).min(by: { $0.size < $1.size }) else {
            throw ArchiveFailure.message("未找到可确认密码的加密文件。")
        }
        _ = try run(["t", "-y", "-spd", "-sccUTF-8", "-i!\(entry.path)", "--", archive.path], password: password)
    }

    public func list(_ archive: URL, password: String = "") throws -> [ArchiveEntry] {
        let output = try run(["l", "-slt", "-ba", "-sccUTF-8", "--", archive.path], password: password)
        return try Self.parseListing(output)
    }

    /// Read headers only. In particular, opening a large archive never runs `x`.
    public func catalog(_ archive: URL, password: String = "") throws -> ArchiveCatalog {
        let output = try run(["l", "-slt", "-sccUTF-8", "--", archive.path], password: password)
        guard let separator = output.range(of: "\n----------\n"),
              let headerStart = output.range(of: "\n--\n"), headerStart.upperBound <= separator.lowerBound else {
            throw ArchiveFailure.message("无法读取压缩包目录。")
        }
        let header = String(output[headerStart.upperBound..<separator.lowerBound])
        let body = String(output[separator.upperBound...])
        let type = header.components(separatedBy: .newlines).first { $0.hasPrefix("Type = ") }?.dropFirst(7)
        let singleStream = ["gzip", "bzip2", "xz", "lzma", "lzma86", "Z", "zstd"].contains(String(type ?? ""))
        var entries = try Self.parseListing(body)
        // A raw stream has a single logical file, sometimes without a stored name
        // or size. Show that file without decompressing it just to discover them.
        if entries.isEmpty && singleStream {
            let name = archive.deletingPathExtension().lastPathComponent
            entries = try Self.parseListing("Path = \(name)\n" + body)
        }
        try checkCancellation()
        return ArchiveCatalog(entries: entries, isSolid: header.components(separatedBy: .newlines).contains("Solid = +"),
                              isSingleStream: singleStream)
    }

    public static func parseListing(_ output: String) throws -> [ArchiveEntry] {
        var rows: [ArchiveEntry] = []
        var fields: [String: String] = [:]
        func commit() throws {
            guard let path = fields["Path"] else { fields = [:]; return }
            try validatePath(path)
            let attributes = fields["Attributes"] ?? ""
            let mode = fields["Mode"] ?? ""
            if !(fields["Symbolic Link"] ?? "").isEmpty || !(fields["Hard Link"] ?? "").isEmpty || !(fields["Copy Link"] ?? "").isEmpty ||
                attributes.split(separator: " ").contains(where: { $0.hasPrefix("l") }) || mode.hasPrefix("l") {
                throw ArchiveFailure.message("此压缩包包含符号链接或硬链接，初版暂不解压此类文件：\(path)")
            }
            let sizeIsKnown = !(fields["Size"] ?? "").isEmpty
            let size = sizeIsKnown ? (Int64(fields["Size"]!) ?? -1) : 0
            guard size >= 0 else { throw ArchiveFailure.message("压缩包内的文件大小无效。") }
            rows.append(ArchiveEntry(id: rows.count, path: path, size: size,
                isDirectory: fields["Folder"] == "+" || attributes.hasPrefix("D") || attributes.hasPrefix("d") || mode.hasPrefix("d"),
                isEncrypted: fields["Encrypted"] == "+", sizeIsKnown: sizeIsKnown))
            fields = [:]
        }
        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty { try commit(); continue }
            if line == "Enter password:" { continue }
            guard let range = line.range(of: " = ") else {
                throw ArchiveFailure.message("文件列表含有无法识别的内容或换行文件名，无法安全解压。")
            }
            let key = String(line[..<range.lowerBound])
            guard fields[key] == nil else { throw ArchiveFailure.message("压缩包目录存在重复字段，无法安全解压。") }
            fields[key] = String(line[range.upperBound...])
        }
        try commit()
        var seen: [String: Bool] = [:]
        for row in rows {
            let key = row.path.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").filter { $0 != "." }.joined(separator: "/")
                .precomposedStringWithCanonicalMapping.lowercased()
            guard !key.isEmpty, seen[key] == nil else {
                throw ArchiveFailure.message("压缩包存在重名或大小写冲突的文件，初版无法无损展开：\(row.path)")
            }
            seen[key] = row.isDirectory
        }
        for key in seen.keys {
            var parts = key.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                if seen[parts.joined(separator: "/")] == false {
                    throw ArchiveFailure.message("压缩包中存在文件与目录的路径冲突。")
                }
            }
        }
        return rows
    }

    public static func validatePath(_ path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !components.contains(".."),
              !normalized.contains(":"), !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveFailure.message("压缩包包含不安全的文件路径：\(path)")
        }
    }

    public func extract(_ archive: URL, into parent: URL, password: String = "",
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> URL {
        let entries = try list(archive, password: password)
        var total: Int64 = 0
        for item in entries {
            let next = total.addingReportingOverflow(item.size)
            guard !next.overflow else { throw ArchiveFailure.message("压缩包标记的解压大小过大。") }
            total = next.partialValue
        }
        let capacity = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, total > capacity { throw ArchiveFailure.message("解压需要约 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))，目标磁盘空间不足。") }
        let stage = try makeStage(in: parent)
        defer { try? FileManager.default.removeItem(at: stage) }
        _ = try run(["x", "-y", "-aos", "-bsp1", "-bso1", "-bse1", "-sccUTF-8", "-o\(stage.path)", "--", archive.path],
                    password: password, writeRoot: stage, progress: progress)
        try checkCancellation()
        // Refuse links even if an unusual format did not expose them in its listing.
        try inspectTree(stage)
        let stem = Self.archiveStem(archive.lastPathComponent)
        let target = Self.uniqueURL(parent: parent, stem: stem, ext: "")
        try FileManager.default.moveItem(at: stage, to: target)
        progress(1)
        return target
    }

    /// Materialize exactly one member in a private cache slot. `-spd` disables
    /// wildcard expansion and `-i!` keeps names starting with @ or - literal.
    /// Flattening this one member avoids creating its archive-supplied parents.
    public func extractMember(_ archive: URL, entry: ArchiveEntry, singleStream: Bool = false,
                              into parent: URL, password: String = "",
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> URL {
        try checkCancellation()
        try Self.validatePath(entry.path)
        guard !entry.isDirectory else { throw ArchiveFailure.message("文件夹无需解压即可浏览。") }
        let capacity = try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, entry.sizeIsKnown && entry.size > capacity {
            throw ArchiveFailure.message("打开这个文件需要约 \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))，磁盘空间不足。")
        }
        let stage = try makeStage(in: parent)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: stage) } }
        var arguments = ["e", "-y", "-aos", "-spd", "-ssc", "-r-", "-bsp1", "-bso1", "-bse1", "-sccUTF-8", "-o\(stage.path)"]
        if !singleStream { arguments.append("-i!\(entry.path)") }
        arguments += ["--", archive.path]
        _ = try run(arguments, password: password, writeRoot: stage, progress: progress)
        try checkCancellation()
        try inspectTree(stage)
        let outputs = try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.isRegularFileKey])
        guard outputs.count == 1, let file = outputs.first,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              singleStream || file.lastPathComponent == entry.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) else {
            throw ArchiveFailure.message("未能单独读取所选文件，请重新打开压缩包后重试。")
        }
        progress(1)
        try checkCancellation()
        succeeded = true
        return file
    }

    public func compress(_ inputs: [URL], into parent: URL, name: String, format: String,
                         level: Int = 5, password: String = "",
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) throws -> URL {
        guard ["zip", "7z"].contains(format), !inputs.isEmpty else { throw ArchiveFailure.message("请选择文件，并使用 ZIP 或 7Z 格式。") }
        if format == "zip" && password.unicodeScalars.contains(where: { $0.value > 0x7f }) {
            throw ArchiveFailure.message("ZIP 加密密码请使用英文字母、数字或英文符号；中文密码请选择 7Z 格式。")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validatePath(name)
        guard !name.contains("/"), !name.contains("\\"), name != "." else { throw ArchiveFailure.message("请输入有效的压缩包名称。") }
        let items = inputs.map { $0.standardizedFileURL }
        let resolvedParent = parent.resolvingSymlinksInPath().path
        for item in items {
            try checkCancellation()
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ArchiveFailure.message("初版暂不压缩符号链接，请选择原文件。") }
            let path = item.resolvingSymlinksInPath().path
            if values.isDirectory == true && (resolvedParent == path || resolvedParent.hasPrefix(path + "/")) {
                throw ArchiveFailure.message("保存位置不能位于待压缩文件夹内，请选择该文件夹的上级或其他目录。")
            }
            try inspectTree(item)
        }
        var common = items[0].deletingLastPathComponent()
        while !items.allSatisfy({ $0.path.hasPrefix(common.path == "/" ? "/" : common.path + "/") }) {
            common.deleteLastPathComponent()
        }
        let paths = items.map { String($0.path.dropFirst(common.path == "/" ? 1 : common.path.count + 1)) }
        let stage = try makeStage(in: parent)
        defer { try? FileManager.default.removeItem(at: stage) }
        let temp = stage.appendingPathComponent("archive.\(format)")
        var args = ["a", "-t\(format)", "-mx=\(max(0, min(level, 9)))", "-mmt=4", "-bsp1", "-bso1", "-bse1", "-sccUTF-8", "-y", "-spd", "-snl"]
        if format == "zip" { args.append("-mcu=on") }
        if !password.isEmpty {
            args.append("-p")
            args.append(format == "7z" ? "-mhe=on" : "-mem=AES256")
        }
        // Prefix relative names so an actual @name is never interpreted as a list file.
        args += [temp.path, "--"] + paths.map { "./" + $0 }
        _ = try run(args, password: password, directory: common, progress: progress)
        try checkCancellation()
        let stem = name.lowercased().hasSuffix(".\(format)") ? String(name.dropLast(format.count + 1)) : name
        guard !stem.isEmpty else { throw ArchiveFailure.message("压缩包名称不能为空。") }
        let target = Self.uniqueURL(parent: parent, stem: stem, ext: format)
        try FileManager.default.moveItem(at: temp, to: target)
        progress(1)
        return target
    }

    private func inspectTree(_ root: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        func inspect(_ url: URL) throws {
            try checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { throw ArchiveFailure.message("初版暂不处理符号链接：\(url.lastPathComponent)") }
            if values.isDirectory != true && values.isRegularFile != true { throw ArchiveFailure.message("暂不处理特殊文件：\(url.lastPathComponent)") }
            if url.lastPathComponent.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw ArchiveFailure.message("暂不处理文件名带换行或控制字符的文件。")
            }
        }
        try inspect(root)
        if (try root.resourceValues(forKeys: keys)).isDirectory == true {
            var traversalError: Error?
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                traversalError = error; return false
            }) else { throw ArchiveFailure.message("无法读取文件夹。") }
            for case let item as URL in enumerator { try inspect(item) }
            if let traversalError { throw traversalError }
        }
    }

    private func makeStage(in parent: URL) throws -> URL {
        let stage = parent.appendingPathComponent(".lightzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }

    public static func uniqueURL(parent: URL, stem: String, ext: String) -> URL {
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let url = parent.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: url.path) && (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil { return url }
            index += 1
        }
    }

    public static func archiveStem(_ name: String) -> String {
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".7z.001", ".zip.001"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? "解压文件" : base
    }
}
