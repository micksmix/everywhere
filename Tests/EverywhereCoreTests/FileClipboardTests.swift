import AppKit
import XCTest
@testable import EverywhereCore

final class FileClipboardTests: XCTestCase {
    func testSingleFileWritesAFileURL() throws {
        try fixture { pasteboard in
            let path = "/clipboard-fixture/report.txt"
            XCTAssertTrue(FileClipboard.copyFiles([path], to: pasteboard))
            let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
            let value = try XCTUnwrap(item.string(forType: .fileURL))
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, path)
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        }
    }

    func testMultipleFileURLsPreserveOrderAndSpecialCharacters() throws {
        try fixture { pasteboard in
            let paths = [
                "/clipboard-fixture/annual report.pdf",
                "/clipboard-fixture/München-文件#100%.txt",
                "/clipboard-fixture/line\nbreak.txt",
                "/clipboard-fixture/a folder/"
            ]
            XCTAssertTrue(FileClipboard.copyFiles(paths, to: pasteboard))
            let values = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
            XCTAssertEqual(values, paths.map { URL(fileURLWithPath: $0) })
            XCTAssertEqual(pasteboard.pasteboardItems?.count, paths.count)
            for item in pasteboard.pasteboardItems ?? [] {
                XCTAssertNotNil(item.string(forType: .fileURL))
            }
        }
    }

    func testFileCopyReplacesExistingClipboardContents() throws {
        try fixture { pasteboard in
            pasteboard.setString("previous text", forType: .string)
            XCTAssertTrue(FileClipboard.copyFiles(["/clipboard-fixture/new.txt"], to: pasteboard))
            let values = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
            XCTAssertEqual(values.map(\.path), ["/clipboard-fixture/new.txt"])
            XCTAssertNotEqual(pasteboard.string(forType: .string), "previous text")
        }
    }

    func testEmptySelectionDoesNotClearThePasteboard() {
        fixture { pasteboard in
            pasteboard.setString("keep this", forType: .string)
            let changeCount = pasteboard.changeCount
            XCTAssertFalse(FileClipboard.copyFiles([], to: pasteboard))
            XCTAssertEqual(pasteboard.changeCount, changeCount)
            XCTAssertEqual(pasteboard.string(forType: .string), "keep this")
        }
    }

    private func fixture(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }
}
