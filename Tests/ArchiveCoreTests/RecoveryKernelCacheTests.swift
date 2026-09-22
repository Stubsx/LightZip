import XCTest
@testable import ArchiveCore

final class RecoveryKernelCacheTests: XCTestCase {
    func testOnlyRegularCompiledProgramsPersistAndRestore() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lightzip-cache-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools")
        try fm.createDirectory(at: tools.appendingPathComponent("hashcat"), withIntermediateDirectories: true)
        let manifest = tools.appendingPathComponent("hashcat/cache-version")
        try Data(String(repeating: "a", count: 64).utf8).write(to: manifest)
        let cache = try XCTUnwrap(RecoveryKernelCache(toolsDirectory: tools, root: root.appendingPathComponent("cache")))
        let job = root.appendingPathComponent("job"), kernels = job.appendingPathComponent("kernels")
        try fm.createDirectory(at: kernels, withIntermediateDirectories: true)
        let binary = kernels.appendingPathComponent("m11600-pure.abcdef12.kernel")
        try Data("compiled program".utf8).write(to: binary)
        for name in ["archive.hash", "recovered.hex", "candidates.txt", "session.log"] {
            try Data("private job content".utf8).write(to: kernels.appendingPathComponent(name))
        }
        try fm.createSymbolicLink(at: kernels.appendingPathComponent("symlink.kernel"), withDestinationURL: binary)
        try cache.save(from: job)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: cache.directory.path), [binary.lastPathComponent])
        let saved = cache.directory.appendingPathComponent(binary.lastPathComponent)
        XCTAssertEqual((try fm.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("new compiled program".utf8).write(to: binary)
        try cache.save(from: job)
        XCTAssertEqual(try Data(contentsOf: saved), Data("new compiled program".utf8))
        let next = root.appendingPathComponent("next-job")
        XCTAssertEqual(try cache.restore(to: next), 1)
        XCTAssertEqual(try Data(contentsOf: next.appendingPathComponent("kernels/" + binary.lastPathComponent)), Data("new compiled program".utf8))
        // A different shipped runtime cannot reuse this namespace.
        try Data(String(repeating: "b", count: 64).utf8).write(to: manifest)
        let updated = try XCTUnwrap(RecoveryKernelCache(toolsDirectory: tools, root: root.appendingPathComponent("cache")))
        XCTAssertNotEqual(updated.directory, cache.directory)
        XCTAssertEqual(try updated.restore(to: root.appendingPathComponent("new-version-job")), 0)
        cache.invalidate()
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: cache.directory.path).isEmpty)
    }

    func testSourcePathStaysStableAcrossJobsAndBinaryInvalidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lightzip-source-cache-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools"), source = tools.appendingPathComponent("hashcat/OpenCL")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appendingPathComponent("kernel.cl"))
        try Data(String(repeating: "c", count: 64).utf8).write(to: tools.appendingPathComponent("hashcat/cache-version"))
        let cache = try XCTUnwrap(RecoveryKernelCache(toolsDirectory: tools, root: root.appendingPathComponent("cache")))
        let first = try cache.prepareSources(from: source)
        cache.invalidate()
        let second = try cache.prepareSources(from: source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("kernel.cl")), Data("source".utf8))
    }

    func testMissingManifestAndCacheFailureDetection() {
        XCTAssertNil(RecoveryKernelCache(toolsDirectory: URL(fileURLWithPath: "/missing-runtime"), root: URL(fileURLWithPath: "/unused")))
        XCTAssertTrue(PasswordRecovery.isKernelCacheFailure("clCreateProgramWithBinary(): CL_INVALID_BINARY"))
        XCTAssertTrue(PasswordRecovery.isKernelCacheFailure("Self-test failed"))
        XCTAssertFalse(PasswordRecovery.isKernelCacheFailure("Finished self-test. No devices found/left."))
        XCTAssertFalse(PasswordRecovery.isKernelCacheFailure("Host memory allocated for this attack"))
    }
}
