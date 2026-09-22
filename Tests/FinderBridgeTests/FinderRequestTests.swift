import XCTest
@testable import FinderBridge

final class FinderRequestTests: XCTestCase {
    private var directory: URL!
    private var store: FinderRequestStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lightzip-finder-tests-\(UUID().uuidString)")
        store = FinderRequestStore(directory: directory)
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }

    func testMenuChoosesRelevantOperation() {
        for name in ["资料.ZIP", "a.7z", "a.rar", "a.tar.gz", "a.tgz", "a.7z.001", "a.zip.001", "a.xz"] {
            XCTAssertEqual(FinderAction.forSelection([URL(fileURLWithPath: "/tmp/" + name)], isDirectory: { _ in false }), .extract)
        }
        let archive = URL(fileURLWithPath: "/tmp/a.zip")
        XCTAssertEqual(FinderAction.forSelection([archive], isDirectory: { _ in true }), .compress)
        XCTAssertEqual(FinderAction.forSelection([archive, archive], isDirectory: { _ in false }), .compress)
        XCTAssertEqual(FinderAction.forSelection([URL(fileURLWithPath: "/tmp/note.txt")], isDirectory: { _ in false }), .compress)
        XCTAssertNil(FinderAction.forSelection([], isDirectory: { _ in false }))
        XCTAssertNil(FinderAction.forSelection([URL(string: "https://example.com/a.zip")!], isDirectory: { _ in false }))
    }

    func testTicketPreservesSelectionAndCannotReplay() throws {
        let files = [URL(fileURLWithPath: "/tmp/中文 空格 #&?.txt"), URL(fileURLWithPath: "/tmp/@资料")]
        let ticket = try store.enqueue(FinderRequest(action: .compress, files: files))
        XCTAssertFalse(ticket.absoluteString.contains("path"))
        let request = try store.consume(ticket)
        XCTAssertEqual(request.action, .compress)
        XCTAssertEqual(request.files, files)
        XCTAssertThrowsError(try store.consume(ticket))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testRejectsArbitraryLinksAndExpiredTickets() throws {
        for value in ["lightzip://finder?path=/tmp/a.zip", "lightzip://finder/../../a", "lightzip://extract/a.zip", "https://finder/\(UUID().uuidString)", "lightzip://finder/\(UUID().uuidString)?action=extract"] {
            XCTAssertThrowsError(try store.consume(URL(string: value)!))
        }
        let ticket = try store.enqueue(FinderRequest(action: .extract, files: [URL(fileURLWithPath: "/tmp/a.zip")], createdAt: Date().addingTimeInterval(-121)))
        XCTAssertThrowsError(try store.consume(ticket))
    }

    func testRejectsEmptyRemoteAndMultipleExtractionRequests() throws {
        XCTAssertThrowsError(try store.enqueue(FinderRequest(action: .compress, files: [])))
        XCTAssertThrowsError(try store.enqueue(FinderRequest(action: .compress, files: [URL(string: "https://example.com/a")!])))
        XCTAssertThrowsError(try store.enqueue(FinderRequest(action: .extract, files: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])))
    }

    func testRejectsSymlinkTicketWithoutFollowingIt() throws {
        let ticket = try store.enqueue(FinderRequest(action: .extract, files: [URL(fileURLWithPath: "/tmp/a.zip")]))
        let source = directory.appendingPathComponent(ticket.lastPathComponent + ".json")
        let linkID = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(linkID + ".json"), withDestinationURL: source)
        XCTAssertThrowsError(try store.consume(URL(string: "lightzip://finder/" + linkID)!))
        XCTAssertEqual(try store.consume(ticket).action, .extract)
    }
}
