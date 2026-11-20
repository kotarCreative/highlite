import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class NativeCaptureBundleTests: XCTestCase {
    private let sessionId = "native-1763642096789-00000000-0000-4000-8000-000000000000"
    private let note = "Check the total before saving."
    private let createdAtText = "2026-11-20T12:34:56.789Z"

    private func pngFixture() throws -> Data {
        guard let url = Bundle.module.url(forResource: "native-capture", withExtension: "png") else {
            throw XCTSkip("Missing native-capture.png fixture")
        }
        return try Data(contentsOf: url)
    }

    private func createdAt() throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: createdAtText))
    }

    private func bundle() throws -> NativeCaptureBundle {
        try NativeCaptureBundleBuilder.build(
            pngData: try pngFixture(),
            note: "  \(note)  ",
            highlight: NativeCaptureRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25),
            createdAt: try createdAt(),
            sessionId: sessionId
        )
    }

    func testManifestMatchesCanonicalStillCaptureShape() throws {
        let bundle = try bundle()
        XCTAssertEqual(bundle.sessionId, sessionId)
        XCTAssertEqual(bundle.note, note)
        XCTAssertEqual(bundle.imageWidth, 64)
        XCTAssertEqual(bundle.imageHeight, 48)

        let actual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData("native-capture-manifest")) as? [String: Any]
        )
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        )
    }

    func testArchiveRoundTripsThroughStandardUnzip() throws {
        let bundle = try bundle()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeCaptureBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("capture.zip")
        try bundle.archive.write(to: archive)

        XCTAssertEqual(try unzip(archive, entry: "manifest.json"), bundle.manifestJSON)
        XCTAssertEqual(try unzip(archive, entry: "capture.png"), try pngFixture())
    }

    func testBuilderRejectsUnmarkedAndMalformedCaptures() throws {
        let png = try pngFixture()
        let valid = NativeCaptureRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(pngData: Data("not a png".utf8), note: note, highlight: valid)
        ) {
            XCTAssertEqual($0 as? NativeCaptureBundleError, .invalidImage)
        }
        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(pngData: png, note: "   ", highlight: valid)
        ) {
            XCTAssertEqual($0 as? NativeCaptureBundleError, .emptyNote)
        }
        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(
                pngData: png,
                note: note,
                highlight: NativeCaptureRect(x: 0.9, y: 0.1, width: 0.5, height: 0.5)
            )
        ) {
            XCTAssertEqual($0 as? NativeCaptureBundleError, .invalidHighlight)
        }
        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(
                pngData: png,
                note: String(repeating: "a", count: NativeCaptureBundleBuilder.maximumNoteLength + 1),
                highlight: valid
            )
        ) {
            XCTAssertEqual($0 as? NativeCaptureBundleError, .noteTooLong)
        }
    }

    func testDefaultSessionIdentifierMatchesRelayRules() throws {
        let bundle = try NativeCaptureBundleBuilder.build(
            pngData: try pngFixture(),
            note: note,
            highlight: NativeCaptureRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            createdAt: try createdAt()
        )
        XCTAssertTrue(bundle.sessionId.hasPrefix("native-1763642096789-"))
        XCTAssertLessThanOrEqual(bundle.sessionId.utf8.count, 128)
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"
        )
        XCTAssertTrue(bundle.sessionId.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertFalse(bundle.sessionId.contains(".."))
    }

    func testCaptureCommandUsesInteractiveSystemUI() {
        XCTAssertEqual(NativeCaptureCommand.executablePath, "/usr/sbin/screencapture")
        XCTAssertEqual(
            NativeCaptureCommand.arguments(outputPath: "/tmp/capture.png"),
            ["-i", "-x", "-t", "png", "/tmp/capture.png"]
        )
    }

    private func unzip(_ archive: URL, entry: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "unzip failed: \(String(decoding: errorData, as: UTF8.self))"
        )
        return data
    }
}
