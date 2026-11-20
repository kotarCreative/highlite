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

    func testManifestCarriesEveryBrowserAnnotationKind() throws {
        let annotations = [
            NativeCaptureAnnotation(kind: .freehand, points: [
                NativeCapturePoint(x: 0.10, y: 0.15),
                NativeCapturePoint(x: 0.20, y: 0.30),
                NativeCapturePoint(x: 0.30, y: 0.20),
            ]),
            NativeCaptureAnnotation(kind: .circle, points: [
                NativeCapturePoint(x: 0.55, y: 0.20),
                NativeCapturePoint(x: 0.80, y: 0.55),
            ]),
            NativeCaptureAnnotation(kind: .arrow, points: [
                NativeCapturePoint(x: 0.15, y: 0.70),
                NativeCapturePoint(x: 0.45, y: 0.85),
            ]),
            NativeCaptureAnnotation(kind: .highlight, points: [
                NativeCapturePoint(x: 0.55, y: 0.65),
                NativeCapturePoint(x: 0.90, y: 0.85),
            ]),
        ]
        let bundle = try NativeCaptureBundleBuilder.build(
            pngData: try pngFixture(),
            note: note,
            annotations: annotations,
            createdAt: try createdAt(),
            sessionId: sessionId
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        let manifestAnnotations = try XCTUnwrap(root["annotations"] as? [[String: Any]])
        XCTAssertEqual(
            manifestAnnotations.compactMap { $0["kind"] as? String },
            ["freehand", "circle", "arrow", "highlight"]
        )
        XCTAssertEqual(
            manifestAnnotations.compactMap { $0["id"] as? String },
            ["native-freehand", "native-circle", "native-arrow", "native-highlight"]
        )
        let freehandPoints = try XCTUnwrap(
            manifestAnnotations[0]["points"] as? [[String: Any]]
        )
        XCTAssertEqual(freehandPoints.count, 3, "Freehand must keep every sampled point")

        let timeline = try XCTUnwrap(root["timeline"] as? [[String: Any]])
        XCTAssertEqual(timeline.count, 4)
        XCTAssertEqual(timeline.compactMap { $0["seq"] as? Int }, [0, 1, 2, 3])
        XCTAssertEqual(
            timeline.compactMap {
                ($0["payload"] as? [String: Any])?["annotationKind"] as? String
            },
            ["freehand", "circle", "arrow", "highlight"]
        )

        let keyframes = try XCTUnwrap(root["keyframes"] as? [[String: Any]])
        let keyframe = try XCTUnwrap(keyframes.first)
        XCTAssertEqual(
            keyframe["annotationIds"] as? [String],
            ["native-freehand", "native-circle", "native-arrow", "native-highlight"]
        )
        XCTAssertEqual(
            keyframe["eventIds"] as? [String],
            ["native-annotation-1", "native-annotation-2", "native-annotation-3", "native-annotation-4"]
        )
        XCTAssertEqual(keyframe["reason"] as? String, "annotation")
    }

    func testRepeatedAnnotationKindsReceiveDistinctIdentifiers() throws {
        let bundle = try NativeCaptureBundleBuilder.build(
            pngData: try pngFixture(),
            note: note,
            annotations: [
                NativeCaptureAnnotation(kind: .circle, points: [
                    NativeCapturePoint(x: 0.1, y: 0.1),
                    NativeCapturePoint(x: 0.3, y: 0.3),
                ]),
                NativeCaptureAnnotation(kind: .circle, points: [
                    NativeCapturePoint(x: 0.4, y: 0.4),
                    NativeCapturePoint(x: 0.6, y: 0.6),
                ]),
            ],
            createdAt: try createdAt(),
            sessionId: sessionId
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bundle.manifestJSON) as? [String: Any]
        )
        let annotations = try XCTUnwrap(root["annotations"] as? [[String: Any]])
        XCTAssertEqual(
            annotations.compactMap { $0["id"] as? String },
            ["native-circle", "native-circle-2"]
        )
    }

    func testBuilderRequiresRenderableAnnotations() throws {
        let png = try pngFixture()
        let arrow = NativeCaptureAnnotation(kind: .arrow, points: [
            NativeCapturePoint(x: 0.1, y: 0.1),
            NativeCapturePoint(x: 0.8, y: 0.8),
        ])

        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(pngData: png, note: note, annotations: [])
        ) {
            XCTAssertEqual($0 as? NativeCaptureBundleError, .missingAnnotation)
        }
        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(
                pngData: png,
                note: note,
                annotations: [
                    NativeCaptureAnnotation(kind: .arrow, points: [
                        NativeCapturePoint(x: 0.9, y: 0.1),
                        NativeCapturePoint(x: 1.4, y: 0.8),
                    ])
                ]
            )
        ) {
            XCTAssertEqual($0 as? NativeCaptureBundleError, .invalidAnnotation)
        }
        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(
                pngData: png,
                note: note,
                annotations: [
                    NativeCaptureAnnotation(kind: .highlight, points: [
                        NativeCapturePoint(x: 0.2, y: 0.2),
                        NativeCapturePoint(x: 0.7, y: 0.2),
                    ])
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? NativeCaptureBundleError,
                .invalidAnnotation,
                "A zero-height highlight would not be visible"
            )
        }
        XCTAssertThrowsError(
            try NativeCaptureBundleBuilder.build(
                pngData: png,
                note: note,
                annotations: [
                    NativeCaptureAnnotation(kind: .freehand, points: [
                        NativeCapturePoint(x: 0.2, y: 0.2),
                    ])
                ]
            )
        ) {
            XCTAssertEqual($0 as? NativeCaptureBundleError, .invalidAnnotation)
        }
        XCTAssertNoThrow(
            try NativeCaptureBundleBuilder.build(pngData: png, note: note, annotations: [arrow])
        )
    }

    func testAnnotationRenderabilityMatchesBrowserGeometry() throws {
        let arrow = NativeCaptureAnnotation(kind: .arrow, points: [
            NativeCapturePoint(x: 0.1, y: 0.1),
            NativeCapturePoint(x: 0.8, y: 0.1),
        ])
        XCTAssertTrue(arrow.isRenderable(imageWidth: 64, imageHeight: 48))
        XCTAssertEqual(try XCTUnwrap(arrow.normalizedBounds?.width), 0.7, accuracy: 1e-9)

        let flatHighlight = NativeCaptureAnnotation(kind: .highlight, points: [
            NativeCapturePoint(x: 0.1, y: 0.5),
            NativeCapturePoint(x: 0.9, y: 0.5),
        ])
        XCTAssertFalse(flatHighlight.isRenderable(imageWidth: 64, imageHeight: 48))

        let singlePointStroke = NativeCaptureAnnotation(kind: .freehand, points: [
            NativeCapturePoint(x: 0.5, y: 0.5),
        ])
        XCTAssertFalse(singlePointStroke.isRenderable(imageWidth: 64, imageHeight: 48))

        let clippedStroke = NativeCaptureAnnotation(kind: .freehand, points: [
            NativeCapturePoint(x: -0.1, y: 0.5),
            NativeCapturePoint(x: 0.5, y: 0.5),
        ])
        XCTAssertFalse(clippedStroke.isRenderable(imageWidth: 64, imageHeight: 48))
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
