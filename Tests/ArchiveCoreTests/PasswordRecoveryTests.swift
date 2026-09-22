import XCTest
@testable import ArchiveCore

final class PasswordRecoveryTests: XCTestCase {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var root: URL!
    var engine: ArchiveEngine!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lightzip-recovery-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = ArchiveEngine(executable: repository.appendingPathComponent("Vendor/7zip/7zz"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func recovery(tools: URL? = nil) -> PasswordRecovery {
        let bundled = ProcessInfo.processInfo.environment["LIGHTZIP_RECOVERY_TOOLS"].map { URL(fileURLWithPath: $0) }
        return PasswordRecovery(toolsDirectory: tools ?? bundled ?? repository.appendingPathComponent("Vendor/recovery"), archiveEngine: engine,
                                temporaryRoot: root, kernelCacheDirectory: root.appendingPathComponent("kernel-cache"))
    }
    func gpuRequired() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIGHTZIP_RECOVERY_INTEGRATION"] == "1", "Set LIGHTZIP_RECOVERY_INTEGRATION=1 to exercise the real GPU backend")
    }
    func file(_ name: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func archive(_ format: String = "zip", password: String = "0003") throws -> URL {
        try engine.compress([file("proof.txt", "Recovery integration fixture\n")], into: root, name: UUID().uuidString, format: format, password: password)
    }
    func checkClean() throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("lightzip-recovery-") })
    }

    func testRejectInvalidRangeAndEmptyDictionary() throws {
        for limits in [(0, 4), (5, 4), (1, 13), (13, 13)] {
            XCTAssertThrowsError(try PasswordRecovery.validate(.mask(characters: .digits, min: limits.0, max: limits.1)))
        }
        XCTAssertThrowsError(try PasswordRecovery.validate(.dictionary(file("empty.txt", ""), rules: .none)))
    }
    func testHashRecordsStripFilenameAndJohnMetadata() {
        XCTAssertEqual(PasswordRecovery.hashRecords("name:$zip2$*data*$/zip2$:file:archive\nwarning\n$7z$0$19$more\n"), ["$zip2$*data*$/zip2$", "$7z$0$19$more"])
        XCTAssertEqual(PasswordRecovery.identifiedModes("  13600 | WinZip | Archive\n 0 | MD5 | Raw\n"), [13600])
        XCTAssertTrue(PasswordRecovery.hashRecords("no encrypted files").isEmpty)
    }
    func testDecodeLeadingZerosAndRejectInvalidResults() throws {
        XCTAssertEqual(try PasswordRecovery.decodePassword(Data("30303033\n".utf8)), "0003")
        for value in ["", "zzz", "1", "ff", "610a62", "610062"] { XCTAssertNil(try PasswordRecovery.decodePassword(Data(value.utf8))) }
    }
    func testIncrementalProgressAndDeviceSpeed() {
        let line = #"prompt {"progress":[3,1000],"guess":{"guess_mask_length":3},"devices":[{"device_name":"Apple GPU","device_type":"GPU","speed":2500}],"rejected":2}"#
        let progress = PasswordRecovery.parseProgress(line, method: .mask(characters: .digits, min: 2, max: 4))
        XCTAssertEqual(progress?.completed, 103)
        XCTAssertEqual(progress?.total, 11100)
        XCTAssertEqual(progress?.speed, 2500)
        XCTAssertEqual(progress?.device, "Apple GPU · GPU")
        XCTAssertEqual(progress?.rejected, 2)
    }
    func testMixedCharacterSpaceAndCounterLimits() throws {
        XCTAssertEqual(RecoveryCharacters.digits.candidateCount(maximum: 4), 11_110)
        XCTAssertEqual(RecoveryCharacters.alphanumeric.candidateCount(maximum: 2), 3_906)
        XCTAssertEqual(RecoveryCharacters.all.candidateCount(maximum: 2), 9_120)
        for characters in RecoveryCharacters.allCases {
            XCTAssertGreaterThan(characters.candidateCount(maximum: characters.maximumLength), 0)
            XCTAssertThrowsError(try PasswordRecovery.validate(.mask(characters: characters, min: 1, max: characters.maximumLength + 1)))
        }
        let line = #"{"progress":[3844,3844],"guess":{"guess_mask_length":2}}"#
        let progress = PasswordRecovery.parseProgress(line, method: .mask(characters: .alphanumeric, min: 1, max: 2))
        XCTAssertEqual(progress?.completed, 3_906)
        XCTAssertEqual(progress?.total, 3_906)
        XCTAssertEqual(progress?.fraction, 1)
    }

    func testBatchedCandidatesCoverExactlySelectedRange() throws {
        for characters in RecoveryCharacters.allCases {
            let url = root.appendingPathComponent("candidates.txt")
            try recovery().writeCandidates(characters: characters, minimum: 1, maximum: 2, to: url)
            let candidates = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            let alphabet = characters.alphabet.map { String(UnicodeScalar($0)) }
            let expected = Set(alphabet + alphabet.flatMap { first in alphabet.map { first + $0 } })
            XCTAssertEqual(Set(candidates), expected)
            XCTAssertEqual(candidates.count, expected.count, "No duplicate or missing candidates")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let url = root.appendingPathComponent("digits.txt")
        try recovery().writeCandidates(characters: .digits, minimum: 3, maximum: 3, to: url)
        let candidates = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(candidates.count, 1000)
        XCTAssertEqual(candidates.first, "000")
        XCTAssertEqual(candidates.last, "999")
        XCTAssertTrue(candidates.allSatisfy { $0.count == 3 })
    }

    func testBatchStorageIsBoundedAndGenerationCanCancel() throws {
        for (characters, expected) in [(RecoveryCharacters.digits, 6), (.alphanumeric, 3), (.all, 3)] {
            XCTAssertEqual(PasswordRecovery.batchedMaximum(characters: characters, minimum: 1, maximum: characters.maximumLength), expected)
        }
        XCTAssertEqual(PasswordRecovery.batchedMaximum(characters: .digits, minimum: 8, maximum: 12), 7)
        let url = root.appendingPathComponent("too-large.txt")
        XCTAssertThrowsError(try recovery().writeCandidates(characters: .digits, minimum: 1, maximum: 12, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let job = recovery(); job.cancel()
        XCTAssertThrowsError(try job.writeCandidates(characters: .digits, minimum: 1, maximum: 6, to: url)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBatchProgressAndContinuationShareOneTotal() {
        let method = RecoveryMethod.mask(characters: .digits, min: 1, max: 7)
        let batched = PasswordRecovery.parseProgress(#"{"progress":[1111110,1111110],"guess":{"guess_mask_length":4294967295}}"#,
                                                    method: method, batchedMaximum: 6)
        XCTAssertEqual(batched?.completed, 1_111_110)
        XCTAssertEqual(batched?.total, 11_111_110)
        XCTAssertEqual(batched?.message, "正在批量尝试 1–6 位密码…")
        let continued = PasswordRecovery.parseProgress(#"{"progress":[100,10000000],"guess":{"guess_mask_length":7}}"#, method: method)
        XCTAssertEqual(continued?.completed, 1_111_210)
        XCTAssertEqual(continued?.total, batched?.total)
    }

    func testGPU7ZBatchedNumericRange() throws {
        try gpuRequired()
        let fixture = try archive("7z")
        for attempt in 1...2 {
            let recorder = ProgressRecorder(), start = Date()
            XCTAssertEqual(try recovery().recover(fixture, method: .mask(characters: .digits, min: 1, max: 6)) { recorder.append($0) }, "0003")
            print("7Z 1–6 digits, attempt \(attempt), including preparation and final verification: \(Date().timeIntervalSince(start)) seconds")
            let values = recorder.values.filter { $0.total > 0 }
            XCTAssertFalse(values.isEmpty)
            XCTAssertTrue(values.allSatisfy { $0.total == 1_111_110 })
            XCTAssertTrue(values.allSatisfy { $0.message.contains("1–6") })
            XCTAssertEqual(values.last?.completed, 2048, "First result must not wait for the full tuned batch")
            try checkClean()
        }
    }

    func testGPUDispatchBoundaryAndExhaustion() throws {
        try gpuRequired()
        // 0937 is candidate 2048; 0938 begins the next batch. The later
        // password requires several growth steps, detecting skipped ranges.
        for password in ["0937", "0938", "9000"] {
            XCTAssertEqual(try recovery().recover(archive(password: password), method: .mask(characters: .digits, min: 1, max: 4)), password)
        }
        let recorder = ProgressRecorder()
        XCTAssertNil(try recovery().recover(archive(password: "not-numeric"), method: .mask(characters: .digits, min: 1, max: 4)) { recorder.append($0) })
        let values = recorder.values.filter { $0.total > 0 }
        XCTAssertEqual(values.last?.completed, 11_110)
        for (previous, next) in zip(values, values.dropFirst()) { XCTAssertLessThanOrEqual(previous.completed, next.completed) }
        try checkClean()
    }

    func testGPUCorruptKernelCacheRebuilds() throws {
        try gpuRequired()
        let input = try archive(), first = recovery()
        XCTAssertEqual(try first.recover(input, method: .mask(characters: .digits, min: 1, max: 4)), "0003")
        let cache = try XCTUnwrap(RecoveryKernelCache(toolsDirectory: first.toolsDirectory, root: root.appendingPathComponent("kernel-cache")))
        let files = try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil)
            .filter { ["kernel", "metallib"].contains($0.pathExtension) }
        XCTAssertFalse(files.isEmpty)
        for file in files { try Data("invalid compiled program".utf8).write(to: file) }
        let recorder = ProgressRecorder()
        XCTAssertEqual(try recovery().recover(input, method: .mask(characters: .digits, min: 1, max: 4)) { recorder.append($0) }, "0003")
        XCTAssertTrue(recorder.values.contains { $0.message == "正在重新准备计算内核…" })
        try checkClean()
    }

    func testGPUContinueAfterBatchedRange() throws {
        try gpuRequired()
        let recorder = ProgressRecorder()
        XCTAssertEqual(try recovery().recover(archive(password: "0000000"), method: .mask(characters: .digits, min: 1, max: 7)) { recorder.append($0) }, "0000000")
        let values = recorder.values.filter { $0.total > 0 }
        XCTAssertTrue(values.contains { $0.completed == 1_111_110 })
        XCTAssertTrue(values.contains { $0.completed > 1_111_110 })
        XCTAssertTrue(values.allSatisfy { $0.total == 11_111_110 })
        for (previous, next) in zip(values, values.dropFirst()) { XCTAssertLessThanOrEqual(previous.completed, next.completed) }
        try checkClean()
    }

    func testGPUCancelDuringBatchedSearch() throws {
        try gpuRequired()
        let job = recovery(), input = try archive("7z", password: "not-numeric")
        let start = Date()
        XCTAssertThrowsError(try job.recover(input, method: .mask(characters: .digits, min: 1, max: 6)) { update in
            if update.total > 0 { job.cancel() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
        try checkClean()
    }

    func testGPUUppercaseAndNumberMask() throws {
        try gpuRequired()
        XCTAssertEqual(try recovery().recover(archive(password: "A1"), method: .mask(characters: .alphanumeric, min: 1, max: 2)), "A1")
        try checkClean()
    }
    func testGPUSymbolMask() throws {
        try gpuRequired()
        for password in ["A!", " !"] {
            XCTAssertEqual(try recovery().recover(archive(password: password), method: .mask(characters: .all, min: 1, max: 2)), password)
        }
        try checkClean()
    }
    func testGPUMixedMaskExhaustionProgress() throws {
        try gpuRequired()
        let recorder = ProgressRecorder()
        XCTAssertNil(try recovery().recover(archive(password: "a!"), method: .mask(characters: .alphanumeric, min: 1, max: 2)) { recorder.append($0) })
        let values = recorder.values.filter { $0.total > 0 }
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last?.completed, 3_906)
        XCTAssertEqual(values.last?.fraction, 1)
        for (previous, next) in zip(values, values.dropFirst()) { XCTAssertLessThanOrEqual(previous.completed, next.completed) }
        try checkClean()
    }
    func testMissingEngineAndPrecancelDoNotLeaveFiles() throws {
        let input = try archive()
        XCTAssertThrowsError(try recovery(tools: root).recover(input, method: .mask(characters: .digits, min: 4, max: 4)))
        let job = recovery(); job.cancel()
        XCTAssertThrowsError(try job.recover(input, method: .mask(characters: .digits, min: 4, max: 4))) { XCTAssertTrue($0 is CancellationError) }
        try checkClean()
    }
    func testUnsupportedAndUnencryptedArchivesCleanUp() throws {
        XCTAssertThrowsError(try recovery().recover(file("plain.txt", "not an archive"), method: .mask(characters: .digits, min: 4, max: 4)))
        let input = try archive(password: "")
        XCTAssertThrowsError(try recovery().recover(input, method: .mask(characters: .digits, min: 4, max: 4)))
        try checkClean()
    }
    func testGPUZIPNumericWithLeadingZeros() throws {
        try gpuRequired()
        let input = try archive(), original = try Data(contentsOf: input)
        XCTAssertEqual(try recovery().recover(input, method: .mask(characters: .digits, min: 2, max: 4)), "0003")
        XCTAssertEqual(try Data(contentsOf: input), original)
        try checkClean()
    }
    func testGPU7ZDictionary() throws {
        try gpuRequired()
        XCTAssertEqual(try recovery().recover(archive("7z"), method: .dictionary(file("words.txt", "wrong\n0003\n"), rules: .none)), "0003")
        try checkClean()
    }
    func testGPUTraditionalZIP() throws {
        try gpuRequired()
        let input = repository.appendingPathComponent("Tests/RecoveryFixtures/zipcrypto.zip")
        XCTAssertEqual(try recovery().recover(input, method: .dictionary(file("words.txt", "wrong\n0003\n"), rules: .none)), "0003")
        try checkClean()
    }
    func testUnavailableDeviceIsFailureRatherThanExhaustion() throws {
        let tools = root.appendingPathComponent("fake-tools")
        let hashcat = tools.appendingPathComponent("hashcat")
        try FileManager.default.createDirectory(at: hashcat, withIntermediateDirectories: true)
        for name in ["OpenCL", "modules", "tunings"] {
            try FileManager.default.createDirectory(at: hashcat.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: hashcat.appendingPathComponent("hashcat.hcstat2"))
        let script = "#!/bin/sh\nif [ \"$1\" = \"--identify\" ]; then\n echo '13600 | WinZip | Archive'\n exit 0\nfi\necho 'No devices found/left.'\nexit 255\n"
        let binary = hashcat.appendingPathComponent("hashcat")
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.createSymbolicLink(at: tools.appendingPathComponent("zip2john"),
            withDestinationURL: repository.appendingPathComponent("Vendor/recovery/zip2john"))
        XCTAssertThrowsError(try recovery(tools: tools).recover(archive(), method: .mask(characters: .digits, min: 4, max: 4))) {
            XCTAssertTrue($0.localizedDescription.contains("计算设备"))
        }
        try checkClean()
    }
    func testGPUBuiltInRules() throws {
        try gpuRequired()
        XCTAssertEqual(try recovery().recover(archive(password: "Test2026"), method: .dictionary(file("words.txt", "test\n"), rules: .common)), "Test2026")
        try checkClean()
    }
    func testGPUCustomRules() throws {
        try gpuRequired()
        let words = try file("words.txt", "000\n"), rules = try file("append.rule", "$3\n")
        XCTAssertEqual(try recovery().recover(archive(), method: .dictionary(words, rules: .custom(rules))), "0003")
        try checkClean()
    }
    func testGPUExhaustion() throws {
        try gpuRequired()
        XCTAssertNil(try recovery().recover(archive(), method: .dictionary(file("words.txt", "wrong\nnot-it\n"), rules: .none)))
        try checkClean()
    }
    func testGPUCancelDuringInitialization() throws {
        try gpuRequired()
        let job = recovery(), input = try archive()
        XCTAssertThrowsError(try job.recover(input, method: .mask(characters: .digits, min: 10, max: 10)) { progress in
            if progress.message.contains("准备查找") {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { job.cancel() }
            }
        }) { XCTAssertTrue($0 is CancellationError) }
        try checkClean()
    }
    func testGPURAR4AndRAR5() throws {
        try gpuRequired()
        let words = try file("words.txt", "wrong\npassword\n")
        for version in [4, 5] {
            let input = repository.appendingPathComponent("Tests/RecoveryFixtures/rar\(version)-headers.rar")
            XCTAssertEqual(try recovery().recover(input, method: .dictionary(words, rules: .none)), "password")
        }
        try checkClean()
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RecoveryProgress] = []
    func append(_ value: RecoveryProgress) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [RecoveryProgress] { lock.lock(); defer { lock.unlock() }; return stored }
}
