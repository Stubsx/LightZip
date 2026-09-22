import Foundation
import Darwin

public enum RecoveryMethod: Sendable {
    case mask(characters: RecoveryCharacters, min: Int, max: Int)
    case dictionary(URL, rules: RecoveryRules)
}

public enum RecoveryCharacters: String, CaseIterable, Sendable {
    case digits, alphanumeric, all

    public var title: String {
        switch self {
        case .digits: return "仅数字"
        case .alphanumeric: return "字母 + 数字"
        case .all: return "字母 + 数字 + 符号"
        }
    }
    public var alphabetSize: UInt64 {
        switch self { case .digits: return 10; case .alphanumeric: return 62; case .all: return 95 }
    }
    // Keep the complete candidate space within Hashcat's UInt64 counters.
    public var maximumLength: Int {
        switch self { case .digits: return 12; case .alphanumeric: return 10; case .all: return 9 }
    }
    var hashcatDefinition: String {
        switch self { case .digits: return "?d"; case .alphanumeric: return "?l?u?d"; case .all: return "?l?u?d?s" }
    }
    var alphabet: [UInt8] {
        switch self {
        case .digits: return Array("0123456789".utf8)
        case .alphanumeric: return Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        case .all: return Array(UInt8(32)...UInt8(126))
        }
    }
    public func candidateCount(minimum: Int = 1, maximum: Int) -> UInt64 {
        guard minimum >= 1, maximum >= minimum, maximum <= maximumLength else { return 0 }
        var total: UInt64 = 0, count: UInt64 = 1
        for length in 1...maximum {
            count *= alphabetSize
            if length >= minimum { total += count }
        }
        return total
    }
}

public enum RecoveryRules: Sendable {
    case none, common, custom(URL)
}

public struct RecoveryProgress: Sendable {
    public var message: String
    public var completed: Double = 0
    public var total: Double = 0
    public var speed: Double = 0
    public var device: String = ""
    public var rejected: Int = 0
    public var fraction: Double { total > 0 ? min(1, completed / total) : 0 }
    public init(message: String) { self.message = message }
}

/// Each job owns one private directory and one process at a time. Hashcat checks
/// candidates directly; 7-Zip is used only once to verify the recovered result.
public final class PasswordRecovery: @unchecked Sendable {
    public let toolsDirectory: URL
    private let archiveEngine: ArchiveEngine
    private let temporaryRoot: URL
    private let kernelCacheRoot: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private static let modes: Set<Int> = [11600, 12500, 13000, 13600, 17200, 17210, 17220, 17225, 17230, 23700, 23800]

    public init(toolsDirectory: URL, archiveEngine: ArchiveEngine, temporaryRoot: URL = FileManager.default.temporaryDirectory,
                kernelCacheDirectory: URL? = nil) {
        self.toolsDirectory = toolsDirectory
        self.archiveEngine = archiveEngine
        self.temporaryRoot = temporaryRoot
        self.kernelCacheRoot = kernelCacheDirectory ?? RecoveryKernelCache.defaultRoot
    }

    public func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        archiveEngine.cancel()
        if let running { Self.stop(running) }
    }

    private static func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    public func recover(_ archive: URL, method: RecoveryMethod,
                        progress: @escaping @Sendable (RecoveryProgress) -> Void = { _ in }) throws -> String? {
        try checkCancellation()
        try Self.validate(method)
        let fm = FileManager.default
        let source = try fingerprint(archive)
        let bundledHashcat = toolsDirectory.appendingPathComponent("hashcat/hashcat")
        guard fm.isExecutableFile(atPath: bundledHashcat.path) else {
            throw ArchiveFailure.message("密码找回引擎缺失，请重新安装轻压。")
        }
        let stage = temporaryRoot.appendingPathComponent("lightzip-recovery-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        // A real copy is necessary: Hashcat resolves its executable's realpath
        // and otherwise writes kernel caches into the signed application bundle.
        let executable = stage.appendingPathComponent("hashcat")
        try fm.copyItem(at: bundledHashcat, to: executable)
        let kernelCache = RecoveryKernelCache(toolsDirectory: toolsDirectory, root: kernelCacheRoot)
        // The Apple OpenCL compiler drops build options when the resolved
        // include path contains non-ASCII characters (e.g. 轻压.app).
        let sourceKernels = toolsDirectory.appendingPathComponent("hashcat/OpenCL")
        if let cachedSources = try? kernelCache?.prepareSources(from: sourceKernels) {
            try fm.createSymbolicLink(at: stage.appendingPathComponent("OpenCL"), withDestinationURL: cachedSources)
        } else {
            try fm.copyItem(at: sourceKernels, to: stage.appendingPathComponent("OpenCL"))
        }
        for name in ["modules", "tunings", "hashcat.hcstat2"] {
            try fm.createSymbolicLink(at: stage.appendingPathComponent(name),
                                      withDestinationURL: toolsDirectory.appendingPathComponent("hashcat/\(name)"))
        }
        var restoredCache = 0
        do { restoredCache = try kernelCache?.restore(to: stage) ?? 0 }
        catch { try? fm.removeItem(at: stage.appendingPathComponent("kernels")) }
        progress(RecoveryProgress(message: "正在读取加密信息…"))
        let hash = try extractHash(archive, stage: stage)
        let hashURL = stage.appendingPathComponent("archive.hash")
        try privateWrite(Data((hash + "\n").utf8), to: hashURL)
        let identified = try run(executable, ["--identify", hashURL.path], in: stage, limit: 1024 * 1024, timeout: 60)
        guard identified.code == 0, let mode = Self.identifiedModes(identified.output).first else {
            throw ArchiveFailure.message("暂不支持这个压缩包的加密方式，或加密数据不完整。")
        }
        let outputURL = stage.appendingPathComponent("recovered.hex")
        try privateWrite(Data(), to: outputURL)
        var args = ["-m", String(mode), "--potfile-disable", "--restore-disable", "--logfile-disable",
                    "--outfile", outputURL.path, "--outfile-format", "3", "--status", "--status-json",
                    "--status-timer", "1", "--session", "lightzip", "-w", "1"]
        // Coalesce the small lengths into a single wordlist so a GPU batch can
        // contain different lengths. Larger ranges stay lazy masks: never
        // materialize an unbounded search space on disk or in memory.
        var searches: [(arguments: [String], batchedMaximum: Int?)] = []
        switch method {
        case .mask(let characters, let minimum, let maximum):
            // The optimized 7Z kernel supports 20 bytes; all of our bounded
            // ASCII masks fit. Unrestricted user dictionaries keep pure kernels.
            if mode == 11600 { args += ["-O"] }
            let batchedMaximum = Self.batchedMaximum(characters: characters, minimum: minimum, maximum: maximum)
            if batchedMaximum >= minimum {
                progress(RecoveryProgress(message: "正在准备候选…"))
                let candidates = stage.appendingPathComponent("candidates.txt")
                try writeCandidates(characters: characters, minimum: minimum, maximum: batchedMaximum, to: candidates)
                searches.append((["-a", "0", hashURL.path, candidates.path], batchedMaximum))
            }
            if batchedMaximum < maximum {
                searches.append((["-a", "3", "-1", characters.hashcatDefinition, "--markov-disable", "--increment",
                                  "--increment-min", String(max(minimum, batchedMaximum + 1)), "--increment-max", String(maximum),
                                  hashURL.path, String(repeating: "?1", count: maximum)], nil))
            }
        case .dictionary(let dictionary, let rules):
            args += ["-a", "0", hashURL.path, dictionary.path]
            switch rules {
            case .none: break
            case .custom(let url): args += ["-r", url.path]
            case .common:
                let ruleURL = stage.appendingPathComponent("common.rule")
                try privateWrite(Data(Self.commonRules.utf8), to: ruleURL)
                args += ["-r", ruleURL.path]
            }
            searches.append(([], nil))
        }
        var result: (code: Int32, output: String) = (1, "")
        var lastProgress = RecoveryProgress(message: "")
        for search in searches {
            try checkCancellation()
            lastProgress.message = "正在准备查找…"
            progress(lastProgress)
            let receiveLine: (String) -> Void = { line in
                if let update = Self.parseProgress(line, method: method, batchedMaximum: search.batchedMaximum) {
                    lastProgress = update
                    progress(update)
                }
            }
            result = try run(executable, args + search.arguments, in: stage, limit: 256 * 1024, retainTail: true,
                             rampBatches: search.batchedMaximum != nil, line: receiveLine)
            if result.code != 0, result.code != 1, restoredCache > 0, Self.isKernelCacheFailure(result.output) {
                try checkCancellation()
                kernelCache?.invalidate()
                try? fm.removeItem(at: stage.appendingPathComponent("kernels"))
                restoredCache = 0
                lastProgress.message = "正在重新准备计算内核…"
                progress(lastProgress)
                result = try run(executable, args + search.arguments, in: stage, limit: 256 * 1024, retainTail: true,
                                 rampBatches: search.batchedMaximum != nil, line: receiveLine)
            }
            if result.code == 0 || result.code == 1 { try? kernelCache?.save(from: stage) }
            if result.code != 1 { break } // Continue only after exhausting this complete range.
        }
        try checkCancellation()
        guard source == (try fingerprint(archive)) else {
            throw ArchiveFailure.message("压缩包在找回过程中发生了变化，请重新打开后再试。")
        }
        if result.code == 1 { return nil } // Hashcat: exhausted, not an engine error.
        guard result.code == 0 else {
            throw ArchiveFailure.message(Self.engineError(result.output))
        }
        guard let password = try Self.decodePassword(Data(contentsOf: outputURL)), !password.isEmpty else {
            throw ArchiveFailure.message("引擎没有返回有效密码，请换一组候选再试。")
        }
        progress(RecoveryProgress(message: "已找到候选，正在确认密码…"))
        try archiveEngine.verifyRecoveredPassword(archive, password: password)
        try checkCancellation()
        return password
    }

    private func extractHash(_ archive: URL, stage: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let signature = Array(try handle.read(upToCount: 8) ?? Data())
        let command: URL
        let arguments: [String]
        if signature.starts(with: [0x50, 0x4b]) {
            command = toolsDirectory.appendingPathComponent("zip2john"); arguments = [archive.path]
        } else if signature.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) {
            command = URL(fileURLWithPath: "/usr/bin/perl")
            arguments = ["-I" + toolsDirectory.appendingPathComponent("perl/lib/perl5/darwin-thread-multi-2level").path,
                         toolsDirectory.appendingPathComponent("7z2hashcat.pl").path, archive.path]
        } else if signature.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) {
            command = toolsDirectory.appendingPathComponent("rar2john"); arguments = [archive.path]
        } else { throw ArchiveFailure.message("密码找回目前支持 ZIP、7Z 和 RAR 的常见加密方式。") }
        let result = try run(command, arguments, in: stage, limit: 64 * 1024 * 1024, timeout: 120)
        // Converter filenames/diagnostics are never interpreted as commands.
        // Keep only a recognized hash record and strip John-specific metadata.
        guard result.code == 0, let hash = Self.hashRecords(result.output).min(by: { $0.utf8.count < $1.utf8.count }) else {
            throw ArchiveFailure.message("未读取到可用的加密信息。文件可能未加密、分卷不完整，或使用了暂不支持的格式。")
        }
        return hash
    }

    static func hashRecords(_ output: String) -> [String] {
        let pattern = #"\$(?:zip2|pkzip2?|7z|RAR3|rar5)\$[^\r\n:]+"#
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
            guard let range = Range($0.range, in: output) else { return nil }
            return String(output[range]).trimmingCharacters(in: .whitespaces)
        }
    }

    static func identifiedModes(_ output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line -> Int? in
            guard let first = line.split(separator: "|").first,
                  let value = Int(first.trimmingCharacters(in: .whitespaces)), modes.contains(value) else { return nil }
            return value
        }.sorted() // Prefer a single-file PKZIP mode over the generic mixed mode.
    }

    static func validate(_ method: RecoveryMethod) throws {
        switch method {
        case .mask(let characters, let minimum, let maximum):
            guard minimum >= 1, maximum >= minimum, maximum <= characters.maximumLength else {
                throw ArchiveFailure.message("当前密码类型最多支持 \(characters.maximumLength) 位，请调整位数。")
            }
        case .dictionary(let dictionary, let rules):
            var urls = [dictionary]
            if case .custom(let rule) = rules { urls.append(rule) }
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw ArchiveFailure.message("请选择非空的字典或规则文件。")
                }
            }
        }
    }

    /// At most 1.5 million candidates (under 11 MB for the supported alphabets).
    /// This combines 1–6 digits or 1–3 letters/symbols into one GPU search.
    static func batchedMaximum(characters: RecoveryCharacters, minimum: Int, maximum: Int) -> Int {
        var last = minimum - 1
        for length in minimum...maximum {
            if characters.candidateCount(minimum: minimum, maximum: length) > 1_500_000 { break }
            last = length
        }
        return last
    }

    func writeCandidates(characters: RecoveryCharacters, minimum: Int, maximum: Int, to url: URL) throws {
        try Self.validate(.mask(characters: characters, min: minimum, max: maximum))
        guard maximum <= Self.batchedMaximum(characters: characters, minimum: minimum, maximum: maximum) else {
            throw ArchiveFailure.message("候选范围过大，无法建立批量任务。")
        }
        try checkCancellation()
        try privateWrite(Data(), to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let alphabet = characters.alphabet
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024 + maximum + 1)
        for length in minimum...maximum {
            var positions = [Int](repeating: 0, count: length)
            var candidate = [UInt8](repeating: alphabet[0], count: length)
            let count = characters.candidateCount(minimum: length, maximum: length)
            for _ in 0..<count {
                buffer.append(contentsOf: candidate)
                buffer.append(10)
                if buffer.count >= 64 * 1024 {
                    try checkCancellation()
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                for index in (0..<length).reversed() {
                    positions[index] += 1
                    if positions[index] < alphabet.count {
                        candidate[index] = alphabet[positions[index]]
                        break
                    }
                    positions[index] = 0
                    candidate[index] = alphabet[0]
                }
            }
        }
        try checkCancellation()
        try handle.write(contentsOf: buffer)
    }

    static func parseProgress(_ line: String, method: RecoveryMethod, batchedMaximum: Int? = nil) -> RecoveryProgress? {
        guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(line[start...end].utf8)) as? [String: Any],
              let numbers = object["progress"] as? [Double], numbers.count == 2 else { return nil }
        var result = RecoveryProgress(message: "正在校验候选密码…")
        result.completed = numbers[0]; result.total = numbers[1]
        if case .mask(let characters, let minimum, let maximum) = method {
            result.total = Double(characters.candidateCount(minimum: minimum, maximum: maximum))
            if let batchedMaximum {
                let current = Double(characters.candidateCount(minimum: minimum, maximum: batchedMaximum))
                result.completed = min(current, max(0, numbers[0]))
                let range = minimum == batchedMaximum ? "\(minimum)" : "\(minimum)–\(batchedMaximum)"
                result.message = "正在批量尝试 \(range) 位密码…"
            } else {
                let guess = object["guess"] as? [String: Any]
                let length = guess?["guess_mask_length"] as? Int ?? minimum
                guard (minimum...maximum).contains(length) else { return nil }
                let previous = Double(characters.candidateCount(minimum: minimum, maximum: length - 1))
                let current = Double(characters.candidateCount(minimum: length, maximum: length))
                result.completed = previous + min(current, max(0, numbers[0]))
                result.message = "正在批量尝试 \(length) 位密码…"
            }
        }
        let devices = object["devices"] as? [[String: Any]] ?? []
        result.speed = devices.reduce(0) { $0 + ($1["speed"] as? Double ?? 0) }
        result.device = devices.compactMap { device in
            guard let name = device["device_name"] as? String else { return nil }
            return name + " · " + (device["device_type"] as? String ?? "")
        }.joined(separator: "、")
        result.rejected = object["rejected"] as? Int ?? 0
        return result
    }

    static func decodePassword(_ output: Data) throws -> String? {
        guard let line = String(data: output, encoding: .utf8)?.split(separator: "\n").first else { return nil }
        let hex = Array(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard hex.count % 2 == 0, hex.count <= 2048 else { return nil }
        var bytes = [UInt8]()
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let value = UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(value)
        }
        guard let password = String(bytes: bytes, encoding: .utf8),
              !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else { return nil }
        return password
    }

    private func fingerprint(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return [a[.systemNumber], a[.systemFileNumber], a[.size], a[.modificationDate]].map { String(describing: $0) }.joined(separator: "|")
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ArchiveFailure.message("无法建立密码找回任务文件。")
        }
    }

    private func run(_ executable: URL, _ arguments: [String], in directory: URL, limit: Int,
                     timeout: TimeInterval? = nil, retainTail: Bool = false,
                     rampBatches: Bool = false,
                     line: (String) -> Void = { _ in }) throws -> (code: Int32, output: String) {
        try checkCancellation()
        let task = Process(), pipe = Pipe()
        task.executableURL = executable; task.arguments = arguments; task.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        environment.removeValue(forKey: "LIGHTZIP_RAMP_BATCHES")
        if rampBatches { environment["LIGHTZIP_RAMP_BATCHES"] = "1" }
        task.environment = environment
        task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = pipe
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw ArchiveFailure.message("密码找回组件无法启动，请重新安装轻压。") }
        defer { lock.lock(); process = nil; lock.unlock(); try? pipe.fileHandleForReading.close() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        let watchdog = DispatchWorkItem { Self.stop(task) }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog) }
        defer { watchdog.cancel() }
        var data = Data(), pending = Data(), overflow = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit {
                if retainTail { data = data.suffix(limit) }
                else if !overflow { overflow = true; Self.stop(task) }
            }
            if retainTail {
                pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    line(String(decoding: pending[..<end], as: UTF8.self)); pending.removeSubrange(...end)
                }
                if pending.count > limit { pending = pending.suffix(limit) }
            }
            if overflow { data = Data() }
        }
        task.waitUntilExit()
        if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
        try checkCancellation()
        if let deadline, Date() >= deadline { throw ArchiveFailure.message("读取加密信息超时。这个压缩包暂时无法用于密码找回。") }
        if overflow { throw ArchiveFailure.message("加密数据过大，超出当前密码找回引擎的处理上限。") }
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func isKernelCacheFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["cl_invalid_binary", "cl_build_program_failure", "self-test failed", "selftest failed",
                "clcreateprogramwithbinary"].contains(where: text.contains)
            || (text.contains("kernel ") && [" create failed.", " build failed.", " load failed."].contains(where: text.contains))
    }

    private static func engineError(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("no devices") || text.contains("no opencl") || text.contains("no metal") || text.contains("no backends") {
            return "未找到可用的计算设备。当前 Mac 无法运行此加密方式的 GPU 校验。"
        }
        if text.contains("no hashes loaded") || text.contains("token length") || text.contains("signature unmatched") {
            return "引擎不支持这份加密数据，或压缩包已损坏。"
        }
        if text.contains("rule") && (text.contains("invalid") || text.contains("empty")) {
            return "规则文件无效，请选择 Hashcat 格式的规则文件。"
        }
        if ["out of memory", "not enough allocatable", "insufficient memory", "cl_mem_object_allocation_failure"].contains(where: text.contains) {
            return "计算设备内存不足，请关闭其他占用 GPU 的应用后重试。"
        }
        if text.contains("self-test") || text.contains("build") || text.contains("kernel") {
            return "GPU 校验初始化失败，这个设备暂不支持当前加密方式。"
        }
        return "密码找回引擎未能完成任务，请检查字典、规则文件和压缩包后重试。"
    }

    static let commonRules: String = {
        var rules = [":", "l", "u", "c"]
        for suffix in (0...9).map(String.init) + ["!", "123", "1234", "2024", "2025", "2026"] {
            let append = suffix.map { "$\($0)" }.joined()
            rules += [append, "c" + append]
        }
        return rules.joined(separator: "\n") + "\n"
    }()
}
