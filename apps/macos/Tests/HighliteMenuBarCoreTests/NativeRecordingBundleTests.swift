import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class NativeRecordingBundleTests: XCTestCase {
    private let sessionId = "native-1763642096789-00000000-0000-4000-8000-000000000000"
    private let note = "Check the total before saving."
    private let createdAtText = "2026-11-20T12:34:56.789Z"
    private let audioData = Data("fake-m4a-audio".utf8)

    private func posterFixture() throws -> Data {
        guard let url = Bundle.module.url(forResource: "native-capture", withExtension: "png") else {
            throw XCTSkip("Missing native-capture.png fixture")
        }
        return try Data(contentsOf: url)
    }

    private func movieFixture() -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftypisom".utf8))
        data.append(Data("isommp42".utf8))
        data.append(Data("fake-movie-body".utf8))
        return data
    }

    private func createdAt() throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: createdAtText))
    }

    private func bundle(includeAudio: Bool = true) throws -> NativeRecordingBundle {
        try NativeRecordingBundleBuilder.build(
            movieData: movieFixture(),
            posterPNGData: try posterFixture(),
            audioData: includeAudio ? audioData : nil,
            audioFileExtension: "m4a",
            note: "  \(note)  ",
            highlight: NativeCaptureRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25),
            durationMilliseconds: 8_400,
            createdAt: try createdAt(),
            sessionId: sessionId
        )
    }

    func testManifestMatchesCanonicalRecordingShape() throws {
        let bundle = try bundle()
        XCTAssertEqual(bundle.sessionId, sessionId)
        XCTAssertEqual(bundle.note, note)
        XCTAssertEqual(bundle.imageWidth, 64)
        XCTAssertEqual(bundle.imageHeight, 48)
        XCTAssertEqual(bundle.durationMilliseconds, 8_400)
        XCTAssertTrue(bundle.hasMicrophoneAudio)

        let actual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData("native-recording-manifest")) as? [String: Any]
        )
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        )
    }

    func testArchiveRoundTripsAdditiveVideoAndAudioArtifacts() throws {
        let bundle = try bundle()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("recording.zip")
        try bundle.archive.write(to: archive)

        XCTAssertEqual(try unzip(archive, entry: "manifest.json"), bundle.manifestJSON)
        XCTAssertEqual(try unzip(archive, entry: "poster.png"), try posterFixture())
        XCTAssertEqual(try unzip(archive, entry: "recording.mp4"), movieFixture())
        XCTAssertEqual(try unzip(archive, entry: "recording.m4a"), audioData)

        let entries = try unzipEntries(archive)
        XCTAssertEqual(
            entries.sorted(),
            ["manifest.json", "poster.png", "recording.m4a", "recording.mp4"]
        )
    }

    func testRecordingWithoutMicrophoneOmitsAudioArtifact() throws {
        let bundle = try bundle(includeAudio: false)
        XCTAssertFalse(bundle.hasMicrophoneAudio)

        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        let artifacts = try XCTUnwrap(manifest["artifacts"] as? [String: Any])
        XCTAssertEqual(artifacts["video"] as? String, "recording.mp4")
        XCTAssertNil(artifacts["audio"])

        let target = try XCTUnwrap((manifest["targets"] as? [[String: Any]])?.first)
        let metadata = try XCTUnwrap(target["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["microphone"] as? String, "not-included")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("recording.zip")
        try bundle.archive.write(to: archive)
        XCTAssertEqual(
            try unzipEntries(archive).sorted(),
            ["manifest.json", "poster.png", "recording.mp4"]
        )
    }

    func testRecordingWithoutPosterMarkUsesMarkedPosterKeyframe() throws {
        let bundle = try NativeRecordingBundleBuilder.build(
            movieData: movieFixture(),
            posterPNGData: try posterFixture(),
            note: note,
            durationMilliseconds: 1_000,
            createdAt: try createdAt(),
            sessionId: sessionId
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        let keyframe = try XCTUnwrap((manifest["keyframes"] as? [[String: Any]])?.first)
        XCTAssertEqual(keyframe["reason"] as? String, "mark")
        XCTAssertEqual(keyframe["annotationIds"] as? [String], [])
        XCTAssertEqual(keyframe["eventIds"] as? [String], [])
        XCTAssertEqual((manifest["annotations"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((manifest["timeline"] as? [[String: Any]])?.count, 0)
    }

    func testBuilderRejectsMalformedRecordings() throws {
        let poster = try posterFixture()
        let movie = movieFixture()
        let validHighlight = NativeCaptureRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

        func build(
            movieData: Data? = nil,
            posterPNGData: Data? = nil,
            audioData: Data? = nil,
            audioFileExtension: String = "m4a",
            note: String? = nil,
            highlight: NativeCaptureRect? = validHighlight,
            durationMilliseconds: Int = 5_000,
            sessionId: String? = nil
        ) throws -> NativeRecordingBundle {
            try NativeRecordingBundleBuilder.build(
                movieData: movieData ?? movie,
                posterPNGData: posterPNGData ?? poster,
                audioData: audioData,
                audioFileExtension: audioFileExtension,
                note: note ?? self.note,
                highlight: highlight,
                durationMilliseconds: durationMilliseconds,
                createdAt: try createdAt(),
                sessionId: sessionId
            )
        }

        XCTAssertThrowsError(try build(posterPNGData: Data("not a png".utf8))) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidPoster)
        }
        XCTAssertThrowsError(try build(movieData: Data("not a movie".utf8))) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMovie)
        }
        XCTAssertThrowsError(try build(durationMilliseconds: 0)) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidDuration)
        }
        XCTAssertThrowsError(try build(note: "   ")) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .emptyNote)
        }
        XCTAssertThrowsError(
            try build(note: String(repeating: "a", count: NativeRecordingBundleBuilder.maximumNoteLength + 1))
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .noteTooLong)
        }
        XCTAssertThrowsError(
            try build(highlight: NativeCaptureRect(x: 0.9, y: 0.1, width: 0.5, height: 0.5))
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidHighlight)
        }
        XCTAssertThrowsError(try build(audioData: Data())) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidAudio)
        }
        XCTAssertThrowsError(try build(audioData: audioData, audioFileExtension: "m4a;rm")) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidAudioExtension)
        }
        XCTAssertThrowsError(try build(sessionId: "bad/session")) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidSessionId)
        }
    }

    func testDefaultRecordingIdentifierMatchesRelayRules() throws {
        let bundle = try NativeRecordingBundleBuilder.build(
            movieData: movieFixture(),
            posterPNGData: try posterFixture(),
            note: note,
            durationMilliseconds: 1_000,
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

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw XCTSkip("Missing \(name).json fixture")
        }
        return try Data(contentsOf: url)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeRecordingBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

    private func unzipEntries(_ archive: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
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
            "unzip -Z1 failed: \(String(decoding: errorData, as: UTF8.self))"
        )
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
    }
}
