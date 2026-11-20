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

    func testRecordingCarriesPosterAndMomentAnnotations() throws {
        let bundle = try NativeRecordingBundleBuilder.build(
            movieData: movieFixture(),
            posterPNGData: try posterFixture(),
            audioData: audioData,
            audioFileExtension: "m4a",
            note: note,
            annotations: [
                NativeCaptureAnnotation(kind: .freehand, points: [
                    NativeCapturePoint(x: 0.10, y: 0.15),
                    NativeCapturePoint(x: 0.20, y: 0.30),
                ]),
                NativeCaptureAnnotation(kind: .highlight, points: [
                    NativeCapturePoint(x: 0.55, y: 0.65),
                    NativeCapturePoint(x: 0.90, y: 0.85),
                ]),
            ],
            moments: [
                NativeRecordingMoment(
                    atMs: 2_400,
                    pngData: try posterFixture(),
                    annotations: [
                        NativeCaptureAnnotation(kind: .circle, points: [
                            NativeCapturePoint(x: 0.20, y: 0.20),
                            NativeCapturePoint(x: 0.50, y: 0.55),
                        ]),
                        NativeCaptureAnnotation(kind: .arrow, points: [
                            NativeCapturePoint(x: 0.15, y: 0.70),
                            NativeCapturePoint(x: 0.55, y: 0.85),
                        ]),
                    ]
                ),
                NativeRecordingMoment(
                    atMs: 5_200,
                    pngData: try posterFixture(),
                    annotations: [
                        NativeCaptureAnnotation(kind: .highlight, points: [
                            NativeCapturePoint(x: 0.30, y: 0.30),
                            NativeCapturePoint(x: 0.70, y: 0.60),
                        ]),
                    ]
                ),
            ],
            durationMilliseconds: 8_400,
            createdAt: try createdAt(),
            sessionId: sessionId
        )

        XCTAssertEqual(bundle.keyframeCount, 3)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        let annotations = try XCTUnwrap(root["annotations"] as? [[String: Any]])
        XCTAssertEqual(
            annotations.compactMap { $0["kind"] as? String },
            ["freehand", "highlight", "circle", "arrow", "highlight"]
        )
        XCTAssertEqual(
            annotations.compactMap { $0["id"] as? String },
            ["native-freehand", "native-highlight", "native-circle", "native-arrow", "native-highlight-2"]
        )
        XCTAssertEqual(
            annotations.compactMap { $0["atMs"] as? Int },
            [0, 0, 2_400, 2_400, 5_200]
        )
        XCTAssertTrue(
            annotations.allSatisfy {
                ($0["fadeAfterMs"] as? Int) == 0 && ($0["fadeDurationMs"] as? Int) == 1
            },
            "Multi-frame annotations must not bleed into later keyframes"
        )

        let timeline = try XCTUnwrap(root["timeline"] as? [[String: Any]])
        XCTAssertEqual(timeline.compactMap { $0["atMs"] as? Int }, [0, 0, 2_400, 2_400, 5_200])
        XCTAssertEqual(timeline.compactMap { $0["seq"] as? Int }, [0, 1, 2, 3, 4])
        XCTAssertEqual(
            timeline.compactMap { $0["id"] as? String },
            [
                "native-annotation",
                "native-annotation-2",
                "native-annotation-3",
                "native-annotation-4",
                "native-annotation-5",
            ]
        )

        let keyframes = try XCTUnwrap(root["keyframes"] as? [[String: Any]])
        XCTAssertEqual(
            keyframes.compactMap { $0["id"] as? String },
            ["native-frame", "native-frame-2", "native-frame-3"]
        )
        XCTAssertEqual(
            keyframes.compactMap { $0["imagePath"] as? String },
            ["poster.png", "moment-001.png", "moment-002.png"]
        )
        XCTAssertEqual(keyframes.compactMap { $0["atMs"] as? Int }, [0, 2_400, 5_200])
        XCTAssertEqual(
            keyframes.compactMap { $0["annotationIds"] as? [String] },
            [
                ["native-freehand", "native-highlight"],
                ["native-circle", "native-arrow"],
                ["native-highlight-2"],
            ]
        )
        XCTAssertEqual(
            keyframes.compactMap { $0["reason"] as? String },
            ["annotation", "annotation", "annotation"]
        )

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("recording.zip")
        try bundle.archive.write(to: archive)
        XCTAssertEqual(
            try unzipEntries(archive).sorted(),
            [
                "manifest.json",
                "moment-001.png",
                "moment-002.png",
                "poster.png",
                "recording.m4a",
                "recording.mp4",
            ]
        )
        XCTAssertEqual(try unzip(archive, entry: "moment-001.png"), try posterFixture())
    }

    func testMomentBudgetTracksCompilerKeyframeBudget() {
        XCTAssertEqual(
            NativeRecordingBundleBuilder.maximumMoments(forDurationMilliseconds: 8_400),
            5
        )
        XCTAssertEqual(
            NativeRecordingBundleBuilder.maximumMoments(forDurationMilliseconds: 45_000),
            6
        )
        XCTAssertEqual(
            NativeRecordingBundleBuilder.maximumMoments(forDurationMilliseconds: 300_000),
            NativeRecordingBundleBuilder.maximumMomentCount
        )
    }

    func testRecordingMomentCanBeAMarkWithoutAnnotations() throws {
        let bundle = try NativeRecordingBundleBuilder.build(
            movieData: movieFixture(),
            posterPNGData: try posterFixture(),
            note: note,
            annotations: [],
            moments: [
                NativeRecordingMoment(atMs: 1_000, pngData: try posterFixture()),
            ],
            durationMilliseconds: 4_000,
            createdAt: try createdAt(),
            sessionId: sessionId
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        XCTAssertEqual((root["annotations"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((root["timeline"] as? [[String: Any]])?.count, 0)
        let keyframes = try XCTUnwrap(root["keyframes"] as? [[String: Any]])
        XCTAssertEqual(keyframes.count, 2)
        XCTAssertEqual(
            keyframes.compactMap { $0["reason"] as? String },
            ["mark", "mark"]
        )
    }

    func testBuilderRejectsMalformedMoments() throws {
        let poster = try posterFixture()
        let movie = movieFixture()
        let annotation = NativeCaptureAnnotation(kind: .circle, points: [
            NativeCapturePoint(x: 0.2, y: 0.2),
            NativeCapturePoint(x: 0.6, y: 0.6),
        ])
        // A valid 1×1 PNG whose dimensions differ from the poster.
        let onePixelPNG = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            )
        )

        func build(
            annotations: [NativeCaptureAnnotation] = [],
            moments: [NativeRecordingMoment],
            durationMilliseconds: Int = 8_000
        ) throws -> NativeRecordingBundle {
            try NativeRecordingBundleBuilder.build(
                movieData: movie,
                posterPNGData: poster,
                note: note,
                annotations: annotations,
                moments: moments,
                durationMilliseconds: durationMilliseconds,
                createdAt: try createdAt(),
                sessionId: sessionId
            )
        }

        XCTAssertThrowsError(
            try build(moments: [NativeRecordingMoment(atMs: 0, pngData: poster)])
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMoment)
        }
        XCTAssertThrowsError(
            try build(moments: [NativeRecordingMoment(atMs: 100, pngData: poster)])
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMoment)
        }
        XCTAssertThrowsError(
            try build(moments: [
                NativeRecordingMoment(atMs: 2_000, pngData: poster),
                NativeRecordingMoment(atMs: 2_400, pngData: poster),
            ])
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMoment)
        }
        XCTAssertThrowsError(
            try build(moments: [NativeRecordingMoment(atMs: 9_000, pngData: poster)])
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMoment)
        }
        XCTAssertThrowsError(
            try build(moments: [
                NativeRecordingMoment(atMs: 1_000, pngData: Data("not a png".utf8)),
            ])
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMoment)
        }
        XCTAssertThrowsError(
            try build(moments: [NativeRecordingMoment(atMs: 1_000, pngData: onePixelPNG)])
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMoment)
        }
        XCTAssertThrowsError(
            try build(moments: [
                NativeRecordingMoment(
                    atMs: 1_000,
                    pngData: poster,
                    annotations: [
                        NativeCaptureAnnotation(kind: .circle, points: [
                            NativeCapturePoint(x: 0.9, y: 0.1),
                            NativeCapturePoint(x: 1.4, y: 0.5),
                        ])
                    ]
                )
            ])
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidAnnotation)
        }
        XCTAssertThrowsError(
            try build(
                moments: (0..<(NativeRecordingBundleBuilder.maximumMomentCount + 1)).map { index in
                    NativeRecordingMoment(
                        atMs: (index + 1) * NativeRecordingBundleBuilder.minimumMomentGapMilliseconds,
                        pngData: poster,
                        annotations: [annotation]
                    )
                }
            )
        ) {
            XCTAssertEqual($0 as? NativeRecordingBundleError, .invalidMoment)
        }
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
