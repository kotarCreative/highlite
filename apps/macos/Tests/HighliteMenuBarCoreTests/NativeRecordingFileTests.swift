import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class NativeRecordingFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeRecordingFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testRecognizesAnMp4Header() throws {
        let url = root.appendingPathComponent("recording.mp4")
        try writeMovieHeader(to: url)

        XCTAssertTrue(NativeRecordingFile.looksLikeFinalizedMovie(at: url))
    }

    func testRejectsMissingEmptyAndPartialFiles() throws {
        let missing = root.appendingPathComponent("missing.mp4")
        XCTAssertFalse(NativeRecordingFile.looksLikeFinalizedMovie(at: missing))

        let empty = root.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        XCTAssertFalse(NativeRecordingFile.looksLikeFinalizedMovie(at: empty))

        let partial = root.appendingPathComponent("partial.mp4")
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74]).write(to: partial)
        XCTAssertFalse(NativeRecordingFile.looksLikeFinalizedMovie(at: partial))
    }

    func testRejectsFilesWithAnUnrelatedHeader() throws {
        let url = root.appendingPathComponent("not-a-movie.mp4")
        try Data([0x00, 0x00, 0x00, 0x18, 0x6D, 0x64, 0x61, 0x74, 0x00, 0x00, 0x00, 0x00])
            .write(to: url)

        XCTAssertFalse(NativeRecordingFile.looksLikeFinalizedMovie(at: url))
    }

    private func writeMovieHeader(to url: URL) throws {
        // 32-bit box size, `ftyp`, then a short brand. Enough for the header
        // probe; AVFoundation is the authority on actual playability.
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18]
        bytes.append(contentsOf: Array("ftyp".utf8))
        bytes.append(contentsOf: Array("isom".utf8))
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        try Data(bytes).write(to: url)
    }
}
