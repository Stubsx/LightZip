import XCTest
@testable import ArchiveCore

final class FinderSelectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lightzip-service-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("sample".utf8).write(to: root.appendingPathComponent("sample.zip"))
        try Data("document".utf8).write(to: root.appendingPathComponent("中文 文件.txt"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCompressionKeepsMultipleItemsInOrderAndDeduplicates() throws {
        let first = root.appendingPathComponent("中文 文件.txt")
        let second = root.appendingPathComponent("sample.zip")
        let selection = try FinderSelection(operation: .compress, files: [first, second, first])
        XCTAssertEqual(selection.files, [first, second])
        XCTAssertEqual(selection.operation, .compress)
    }
    func testExtractionAcceptsOneFile() throws {
        let archive = root.appendingPathComponent("sample.zip")
        let selection = try FinderSelection(operation: .extract, files: [archive])
        XCTAssertEqual(selection.files, [archive])
    }
    func testExtractionRejectsFoldersAndMultipleArchives() {
        XCTAssertThrowsError(try FinderSelection(operation: .extract, files: [root]))
        XCTAssertThrowsError(try FinderSelection(operation: .extract, files: [root.appendingPathComponent("sample.zip"), root.appendingPathComponent("中文 文件.txt")]))
    }
    func testRejectsEmptyRemoteAndMissingInputs() {
        XCTAssertThrowsError(try FinderSelection(operation: .compress, files: []))
        XCTAssertThrowsError(try FinderSelection(operation: .compress, files: [URL(string: "https://example.com/file.zip")!]))
        XCTAssertThrowsError(try FinderSelection(operation: .compress, files: [root.appendingPathComponent("missing.txt")]))
    }
    func testCompressionAcceptsFolder() throws {
        XCTAssertEqual(try FinderSelection(operation: .compress, files: [root]).files.map(\.path), [root.path])
    }
}
