import XCTest
@testable import ArchiveCore

final class TemporaryArchiveTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var root: URL!
    private var temporary: URL!
    private var engine: ArchiveEngine { ArchiveEngine(executable: repository.appendingPathComponent("Vendor/7zip/7zz")) }
    private let textPath = ["资料", "子目录", "中文 文件.txt"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lightzip-session-tests-\(UUID().uuidString)")
        temporary = root.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func archive(format: String = "7z", password: String = "") throws -> URL {
        let folder = root.appendingPathComponent("资料")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("子目录/空文件夹"), withIntermediateDirectories: true)
        try Data("temporary copy".utf8).write(to: folder.appendingPathComponent("子目录/中文 文件.txt"))
        try Data(repeating: 65, count: 8 * 1024 * 1024).write(to: folder.appendingPathComponent("大文件.bin"))
        return try engine.compress([folder], into: root, name: "样本", format: format, password: password)
    }
    private func cachedFiles(_ session: TemporaryArchive) -> [URL] {
        (FileManager.default.enumerator(at: session.directory, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private func run7zip(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = engine.executable; process.arguments = arguments; process.currentDirectoryURL = root
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
    }

    func testBrowseDoesNotExtractAndAccessCachesOnlyChosenFile() throws {
        let archive = try archive()
        let original = try Data(contentsOf: archive)
        let session = try TemporaryArchive.open(archive, engine: engine, temporaryParent: temporary)
        XCTAssertEqual(try session.items().map(\.name), ["资料"])
        let items = try session.items(in: ["资料", "子目录"])
        XCTAssertEqual(items.map(\.name), ["空文件夹", "中文 文件.txt"])
        XCTAssertTrue(try session.items(in: items[0].components).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: session.directory.path).isEmpty)
        let file = try session.materialize(textPath, engine: engine)
        XCTAssertEqual(try Data(contentsOf: file), Data("temporary copy".utf8))
        XCTAssertEqual(cachedFiles(session).count, 1)
        XCTAssertEqual(cachedFiles(session).first?.lastPathComponent, "中文 文件.txt")
        try Data("edited".utf8).write(to: file)
        let unavailableEngine = ArchiveEngine(executable: root.appendingPathComponent("not-installed"))
        XCTAssertEqual(try session.materialize(textPath, engine: unavailableEngine), file)
        XCTAssertEqual(try Data(contentsOf: file), Data("edited".utf8))
        XCTAssertEqual(try Data(contentsOf: archive), original)
        let unrelated = temporary.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try session.close(); try session.close()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), ["keep.txt"])
    }

    func testImplicitDirectoriesAndLiteralSelection() throws {
        let folder = root.appendingPathComponent("隐式/子目录")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "@文件[1]*?.txt"
        try Data("selected".utf8).write(to: folder.appendingPathComponent(name))
        try Data("sibling".utf8).write(to: folder.appendingPathComponent("@文件[1]ab.txt"))
        let zip = root.appendingPathComponent("literal.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipper.currentDirectoryURL = root
        zipper.arguments = ["-q", zip.path, "隐式/子目录/" + name, "隐式/子目录/@文件[1]ab.txt"]
        try zipper.run(); zipper.waitUntilExit()
        XCTAssertEqual(zipper.terminationStatus, 0)
        XCTAssertFalse(try engine.list(zip).contains { $0.isDirectory })
        let session = try TemporaryArchive.open(zip, engine: engine, temporaryParent: temporary)
        XCTAssertEqual(try session.items().map(\.name), ["隐式"])
        XCTAssertEqual(try session.items(in: ["隐式"]).map(\.name), ["子目录"])
        let file = try session.materialize(["隐式", "子目录", name], engine: engine)
        XCTAssertEqual(try Data(contentsOf: file), Data("selected".utf8))
        XCTAssertEqual(cachedFiles(session).count, 1)
    }

    func testHeaderPasswordAndVisibleEncryptedZIPRetry() throws {
        let locked = try archive(password: "secret")
        XCTAssertThrowsError(try TemporaryArchive.open(locked, engine: engine, password: "wrong", temporaryParent: temporary)) {
            guard case ArchiveFailure.passwordRequired = $0 else { return XCTFail("Expected a password prompt, got \($0)") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        let session = try TemporaryArchive.open(locked, engine: engine, password: "secret", temporaryParent: temporary)
        XCTAssertTrue(session.hasEncryptedFiles)
        XCTAssertTrue(cachedFiles(session).isEmpty)
        _ = try session.materialize(textPath, engine: engine, password: "secret")
        try session.close()
        let zip = try archive(format: "zip", password: "secret")
        let visible = try TemporaryArchive.open(zip, engine: engine, temporaryParent: temporary)
        XCTAssertTrue(visible.hasEncryptedFiles)
        XCTAssertThrowsError(try visible.materialize(textPath, engine: engine, password: "wrong")) {
            guard case ArchiveFailure.passwordRequired = $0 else { return XCTFail("Expected a password prompt, got \($0)") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: visible.directory.path).isEmpty)
        _ = try visible.materialize(textPath, engine: engine, password: "secret")
        XCTAssertEqual(cachedFiles(visible).count, 1)
    }

    func testCancellationAndCorruptionLeaveNoPartialOutput() throws {
        let archive = try archive()
        let cancelled = engine; cancelled.cancel()
        XCTAssertThrowsError(try TemporaryArchive.open(archive, engine: cancelled, temporaryParent: temporary)) { XCTAssertTrue($0 is CancellationError) }
        let session = try TemporaryArchive.open(archive, engine: engine, temporaryParent: temporary)
        let running = engine
        XCTAssertThrowsError(try session.materialize(textPath, engine: running, progress: { _ in running.cancel() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: session.directory.path).isEmpty)
        _ = try session.materialize(textPath, engine: engine)
        try session.close()
        let broken = root.appendingPathComponent("broken.zip")
        try Data("invalid archive".utf8).write(to: broken)
        XCTAssertThrowsError(try TemporaryArchive.open(broken, engine: engine, temporaryParent: temporary))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    func testNavigationAndCacheRejectEscapeAndInjectedLinks() throws {
        let session = try TemporaryArchive.open(archive(), engine: engine, temporaryParent: temporary)
        for components in [[".."], ["资料/子目录"], ["/tmp"], ["资料", ".."]] {
            XCTAssertThrowsError(try session.items(in: components))
            XCTAssertThrowsError(try session.materialize(components, engine: engine))
        }
        let file = try session.materialize(textPath, engine: engine)
        let moved = root.appendingPathComponent("keep.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        XCTAssertThrowsError(try session.materialize(textPath, engine: engine))
        XCTAssertThrowsError(try session.checkedURL(for: textPath))
        try session.close()
        XCTAssertEqual(try Data(contentsOf: moved), Data("temporary copy".utf8))
    }

    func testNestedArchiveOwnersCanBeCleanedIndependently() throws {
        let inner = try archive()
        let outer = try engine.compress([inner], into: root, name: "外层", format: "zip")
        let parent = try TemporaryArchive.open(outer, engine: engine, temporaryParent: temporary)
        let nestedURL = try parent.materialize([inner.lastPathComponent], engine: engine)
        let child = try TemporaryArchive.open(nestedURL, engine: engine, temporaryParent: temporary)
        XCTAssertTrue(parent.contains(nestedURL))
        XCTAssertFalse(parent.contains(outer))
        XCTAssertTrue(cachedFiles(child).isEmpty)
        _ = try child.materialize(textPath, engine: engine)
        try child.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
        try parent.close()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    func testDeinitRemovesCache() throws {
        var session: TemporaryArchive? = try TemporaryArchive.open(archive(), engine: engine, temporaryParent: temporary)
        _ = try session!.materialize(textPath, engine: engine)
        session = nil
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
    }

    func testCanonicalPathMapsBackToVirtualMember() throws {
        let session = try TemporaryArchive.open(archive(), engine: engine, temporaryParent: temporary)
        let file = try session.materialize(textPath, engine: engine)
        let canonical = file.resolvingSymlinksInPath()
        XCTAssertTrue(session.contains(canonical))
        XCTAssertEqual(session.components(for: canonical), textPath)
    }

    func testReadOnlyCacheCanBeCleaned() throws {
        let session = try TemporaryArchive.open(archive(), engine: engine, temporaryParent: temporary)
        let file = try session.materialize(textPath, engine: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: file.deletingLastPathComponent().path)
        try session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
    }

    func testChangedSourceIsRejectedBeforeExtraction() throws {
        let archive = try archive()
        let session = try TemporaryArchive.open(archive, engine: engine, temporaryParent: temporary)
        try Data("changed".utf8).write(to: archive)
        XCTAssertThrowsError(try session.materialize(textPath, engine: engine))
        XCTAssertTrue(cachedFiles(session).isEmpty)
    }

    func testMetadataOnlyChangesDoNotInvalidateContents() throws {
        let archive = try archive()
        let session = try TemporaryArchive.open(archive, engine: engine, temporaryParent: temporary)
        // LaunchServices updates extended attributes such as last-used time,
        // changing ctime while the bytes and content modification time stay put.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let file = try session.materialize(textPath, engine: engine)
        XCTAssertEqual(try Data(contentsOf: file), Data("temporary copy".utf8))
    }

    func testRawStreamsListWithoutExtracting() throws {
        let input = root.appendingPathComponent("stream.txt")
        let content = Data("单文件流\n".utf8)
        try content.write(to: input)
        for format in ["gzip", "bzip2", "xz"] {
            let ext = format == "gzip" ? "gz" : format == "bzip2" ? "bz2" : format
            let archive = root.appendingPathComponent("stream.txt." + ext)
            try run7zip(["a", "-t" + format, archive.path, "--", input.path])
            let session = try TemporaryArchive.open(archive, engine: engine, temporaryParent: temporary)
            let items = try session.items()
            XCTAssertEqual(items.count, 1)
            XCTAssertTrue(cachedFiles(session).isEmpty)
            let file = try session.materialize(items[0].components, engine: engine)
            XCTAssertEqual(try Data(contentsOf: file), content)
            XCTAssertEqual(cachedFiles(session).count, 1)
            try session.close()
        }
    }

    func testRARMemberAndEmptyArchive() throws {
        let session = try TemporaryArchive.open(repository.appendingPathComponent("Tests/rar-windows.rar"), engine: engine, temporaryParent: temporary)
        XCTAssertTrue(cachedFiles(session).isEmpty)
        let file = try session.materialize(["test.txt"], engine: engine)
        XCTAssertEqual(try Data(contentsOf: file), Data("test text file\r\n".utf8))
        XCTAssertEqual(cachedFiles(session).count, 1)
        let empty = root.appendingPathComponent("empty.zip")
        try Data([0x50,0x4b,0x05,0x06] + Array(repeating: UInt8(0), count: 18)).write(to: empty)
        let blank = try TemporaryArchive.open(empty, engine: engine, temporaryParent: temporary)
        XCTAssertTrue(try blank.items().isEmpty)
        XCTAssertTrue(cachedFiles(blank).isEmpty)
    }
}
