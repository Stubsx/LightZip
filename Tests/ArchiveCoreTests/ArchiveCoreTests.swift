import XCTest
@testable import ArchiveCore

final class ArchiveCoreTests: XCTestCase {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var root: URL!
    var engine: ArchiveEngine!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lightzip-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = ArchiveEngine(executable: repository.appendingPathComponent("Vendor/7zip/7zz"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func sample() throws -> URL {
        let folder = root.appendingPathComponent("中文项目")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("空文件夹"), withIntermediateDirectories: true)
        try Data("你好，macOS。\n文件往返验证。".utf8).write(to: folder.appendingPathComponent("资料 空格.txt"))
        try Data((0..<8192).map { UInt8($0 % 256) }).write(to: folder.appendingPathComponent("binary.bin"))
        try Data().write(to: folder.appendingPathComponent("empty.txt"))
        return folder
    }
    func checkRoundTrip(format: String, password: String) throws {
        let input = try sample()
        let archive = try engine.compress([input], into: root, name: "往返", format: format, password: password)
        let listing = try engine.list(archive, password: password)
        XCTAssertTrue(listing.contains { $0.path.contains("资料 空格.txt") })
        let output = try engine.extract(archive, into: root, password: password)
        for file in ["资料 空格.txt", "binary.bin", "empty.txt"] {
            XCTAssertEqual(try Data(contentsOf: input.appendingPathComponent(file)), try Data(contentsOf: output.appendingPathComponent("中文项目/" + file)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("中文项目/空文件夹").path))
        let second = try engine.extract(archive, into: root, password: password)
        XCTAssertNotEqual(output, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("(2)"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lightzip-") })
    }
    func testZIPRoundTrip() throws { try checkRoundTrip(format: "zip", password: "") }
    func test7ZRoundTrip() throws { try checkRoundTrip(format: "7z", password: "") }
    func testEncryptedZIPRoundTrip() throws { try checkRoundTrip(format: "zip", password: "test password!42") }
    func testEncrypted7ZRoundTrip() throws { try checkRoundTrip(format: "7z", password: "密码 test!42") }
    func testWrongPasswordAndCleanup() throws {
        let input = try sample()
        let archive = try engine.compress([input], into: root, name: "locked", format: "zip", password: "right")
        XCTAssertThrowsError(try engine.extract(archive, into: root, password: "wrong"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".lightzip-") || $0 == "locked" })
    }
    func testOverwriteProtection() throws {
        let input = try sample()
        let first = try engine.compress([input], into: root, name: "same", format: "zip")
        let original = try Data(contentsOf: first)
        let second = try engine.compress([input], into: root, name: "same", format: "zip")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(original, try Data(contentsOf: first))
    }
    func testUnsafePathsAndCollisions() throws {
        for path in ["../escape", "/tmp/escape", "a/../../escape", "a\\..\\escape", "C:\\escape", "line\nbreak"] {
            XCTAssertThrowsError(try ArchiveEngine.validatePath(path), path)
        }
        XCTAssertThrowsError(try ArchiveEngine.parseListing("Path = a\nSize = 1\n\nPath = A\nSize = 1\n"))
        XCTAssertThrowsError(try ArchiveEngine.parseListing("Path = a\nSymbolic Link = /tmp\n\n"))
        XCTAssertThrowsError(try ArchiveEngine.parseListing("Path = a\nPath = b\nSize = 1\n"))
    }
    func testOutputInsideSourceRejected() throws {
        let input = try sample()
        XCTAssertThrowsError(try engine.compress([input], into: input, name: "bad", format: "zip"))
    }
    func testCancellationBeforeStart() throws {
        let input = try sample()
        engine.cancel()
        XCTAssertThrowsError(try engine.compress([input], into: root, name: "cancelled", format: "zip")) { XCTAssertTrue($0 is CancellationError) }
    }
    func testCorruptArchive() throws {
        let file = root.appendingPathComponent("broken.rar")
        try Data("not an archive".utf8).write(to: file)
        XCTAssertThrowsError(try engine.extract(file, into: root))
    }
    func testRAR5Fixture() throws {
        let archive = repository.appendingPathComponent("Tests/rar5.rar")
        let listing = try engine.list(archive)
        XCTAssertFalse(listing.isEmpty)
        let output = try engine.extract(archive, into: root)
        for entry in listing where !entry.isDirectory {
            let data = try Data(contentsOf: output.appendingPathComponent(entry.path))
            XCTAssertEqual(Int64(data.count), entry.size)
        }
    }
    func testRARWindowsFixture() throws {
        let output = try engine.extract(repository.appendingPathComponent("Tests/rar-windows.rar"), into: root)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("test.txt")), Data("test text file\r\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("testemptydir").path))
    }
    func testRealUnsafeArchives() throws {
        for name in ["unsafe-path.zip", "symlink.zip", "rar4.rar"] {
            XCTAssertThrowsError(try engine.extract(repository.appendingPathComponent("Tests/" + name), into: root))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testAtSignAndWildcardNames() throws {
        let file = root.appendingPathComponent("@文件[1]*.txt")
        let content = Data("literal filename".utf8)
        try content.write(to: file)
        let archive = try engine.compress([file], into: root, name: "literal", format: "zip")
        let output = try engine.extract(archive, into: root)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(file.lastPathComponent)), content)
    }
    func testUnicodeZIPPasswordRejectedClearly() throws {
        let input = try sample()
        XCTAssertThrowsError(try engine.compress([input], into: root, name: "pw", format: "zip", password: "中文")) {
            XCTAssertTrue($0.localizedDescription.contains("7Z"))
        }
    }
    func testRunningJobCancellationCleansPartialOutput() throws {
        let file = root.appendingPathComponent("large.bin")
        var data = Data(count: 32 * 1024 * 1024)
        data.withUnsafeMutableBytes { buffer in arc4random_buf(buffer.baseAddress!, buffer.count) }
        try data.write(to: file)
        let job = engine!
        let finished = expectation(description: "running compression cancelled")
        DispatchQueue.global().async {
            do {
                _ = try job.compress([file], into: file.deletingLastPathComponent(), name: "cancel", format: "7z", level: 9, progress: { _ in job.cancel() })
                XCTFail("Task should be cancelled")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["large.bin"])
    }
}
