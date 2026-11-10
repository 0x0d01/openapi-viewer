import XCTest
@testable import OpenAPIViewer

final class DocumentReaderTests: XCTestCase {
    func testReadsUTF8SnapshotFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        let source = "openapi: 3.1.0\ninfo:\n  title: Café API\n  version: 1.0.0\n"
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try DocumentReader.readUTF8(from: url), source)
    }

    func testRejectsInvalidUTF8WithUsefulMessage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        try Data([0xC3, 0x28]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DocumentReader.readUTF8(from: url)) { error in
            XCTAssertEqual(
                error.localizedDescription, "The file is not valid UTF-8 text. Save it as UTF-8 and reload.")
        }
    }
}
