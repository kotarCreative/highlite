import Foundation

/// A self-contained native screen recording ready to POST to the relay's local
/// ingest endpoint.
///
/// The archive is additive to the still-capture contract: `manifest.json`,
/// `poster.png`, `recording.mp4`, and optionally `recording.<audio-extension>`.
/// The manifest names the movie and audio through `artifacts.video` and
/// `artifacts.audio`; the canonical compiler treats the poster as the keyframe
/// image exactly as it does for a still capture.
public struct NativeRecordingBundle: Sendable {
    public let sessionId: String
    public let createdAt: Date
    public let note: String
    public let imageWidth: Int
    public let imageHeight: Int
    public let durationMilliseconds: Int
    public let hasMicrophoneAudio: Bool
    public let manifestJSON: Data
    public let archive: Data
}

public enum NativeRecordingBundleError: LocalizedError, Equatable {
    case invalidPoster
    case invalidMovie
    case invalidDuration
    case emptyNote
    case noteTooLong
    case invalidHighlight
    case invalidSessionId
    case invalidAudio
    case invalidAudioExtension
    case archiveTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidPoster:
            return "The recording poster is not a readable PNG image."
        case .invalidMovie:
            return "The recording is not a readable MP4 movie."
        case .invalidDuration:
            return "The recording duration is missing or out of range."
        case .emptyNote:
            return "Add a short note before saving the recording."
        case .noteTooLong:
            return "Keep the note under 2,000 characters."
        case .invalidHighlight:
            return "Draw the poster highlight inside the image."
        case .invalidSessionId:
            return "The recording session identifier is not valid."
        case .invalidAudio:
            return "The microphone audio is empty."
        case .invalidAudioExtension:
            return "The microphone audio file type is not supported."
        case .archiveTooLarge:
            return "The recording is too large to package for the relay."
        }
    }
}

/// Builds a native recording archive without depending on AppKit or the
/// recorder itself. The caller supplies the finalized movie bytes, a poster
/// frame, and optional microphone-audio bytes, so the same code is testable
/// with fixed fixtures.
public enum NativeRecordingBundleBuilder {
    public static let maximumNoteLength = NativeCaptureBundleBuilder.maximumNoteLength
    public static let movieFileName = "recording.mp4"
    public static let posterFileName = "poster.png"
    public static let maximumDurationMilliseconds = 24 * 60 * 60 * 1_000

    private static let pageURL = "highlite://native-capture/recording"

    public static func build(
        movieData: Data,
        posterPNGData: Data,
        audioData: Data? = nil,
        audioFileExtension: String = "m4a",
        note: String,
        highlight: NativeCaptureRect? = nil,
        durationMilliseconds: Int,
        createdAt: Date = Date(),
        sessionId: String? = nil
    ) throws -> NativeRecordingBundle {
        let imageWidth: Int
        let imageHeight: Int
        do {
            (imageWidth, imageHeight) = try NativeCaptureBundleBuilder.imageDimensions(
                in: posterPNGData
            )
        } catch {
            throw NativeRecordingBundleError.invalidPoster
        }
        try validateMovie(movieData)
        guard durationMilliseconds > 0,
              durationMilliseconds <= maximumDurationMilliseconds
        else {
            throw NativeRecordingBundleError.invalidDuration
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else {
            throw NativeRecordingBundleError.emptyNote
        }
        guard trimmedNote.count <= maximumNoteLength else {
            throw NativeRecordingBundleError.noteTooLong
        }
        if let highlight {
            do {
                try NativeCaptureBundleBuilder.validate(
                    highlight,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
            } catch {
                throw NativeRecordingBundleError.invalidHighlight
            }
        }

        let audioFileName: String?
        if let audioData {
            guard !audioData.isEmpty else {
                throw NativeRecordingBundleError.invalidAudio
            }
            guard let name = makeAudioFileName(extension: audioFileExtension) else {
                throw NativeRecordingBundleError.invalidAudioExtension
            }
            audioFileName = name
        } else {
            audioFileName = nil
        }

        let identifier = sessionId ?? NativeCaptureBundleBuilder.defaultSessionId(createdAt: createdAt)
        guard NativeCaptureBundleBuilder.isValidSessionId(identifier) else {
            throw NativeRecordingBundleError.invalidSessionId
        }

        let manifestData = try makeManifest(
            sessionId: identifier,
            createdAt: createdAt,
            note: trimmedNote,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            durationMilliseconds: durationMilliseconds,
            highlight: highlight,
            audioFileName: audioFileName
        )

        var entries = [
            StoredZip.Entry(name: "manifest.json", data: manifestData),
            StoredZip.Entry(name: posterFileName, data: posterPNGData),
            StoredZip.Entry(name: movieFileName, data: movieData),
        ]
        if let audioData, let audioFileName {
            entries.append(StoredZip.Entry(name: audioFileName, data: audioData))
        }

        let archive: Data
        do {
            archive = try StoredZip.archive(entries: entries)
        } catch {
            throw NativeRecordingBundleError.archiveTooLarge
        }

        return NativeRecordingBundle(
            sessionId: identifier,
            createdAt: createdAt,
            note: trimmedNote,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            durationMilliseconds: durationMilliseconds,
            hasMicrophoneAudio: audioFileName != nil,
            manifestJSON: manifestData,
            archive: archive
        )
    }

    private static func validateMovie(_ data: Data) throws {
        let header = [UInt8](data.prefix(12))
        guard header.count == 12,
              Array(header[4..<8]) == Array("ftyp".utf8)
        else {
            throw NativeRecordingBundleError.invalidMovie
        }
    }

    /// The audio container extension is only used for the ZIP entry name and
    /// `artifacts.audio`. Keep it short and path-free; the relay's decoder is
    /// the authority on whether the bytes actually decode.
    private static func makeAudioFileName(extension value: String) -> String? {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bytes = Array(lowered.utf8)
        guard !bytes.isEmpty, bytes.count <= 5,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...122).contains(byte)
              })
        else {
            return nil
        }
        return "recording.\(lowered)"
    }

    private static func makeManifest(
        sessionId: String,
        createdAt: Date,
        note: String,
        imageWidth: Int,
        imageHeight: Int,
        durationMilliseconds: Int,
        highlight: NativeCaptureRect?,
        audioFileName: String?
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let createdAtText = formatter.string(from: createdAt)

        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let viewport = ManifestRect(x: 0, y: 0, width: width, height: height)
        let region = ManifestTarget(
            id: "native-region",
            tag: "screen",
            role: "region",
            label: note,
            textExcerpt: note,
            selector: nil,
            rect: viewport,
            pageUrl: pageURL,
            metadata: [
                "source": "macos-native",
                "captureMode": "recording",
                "microphone": audioFileName == nil ? "not-included" : "included",
            ]
        )

        let annotations: [ManifestAnnotation]
        let timeline: [ManifestTimelineEvent]
        let annotationIds: [String]
        let eventIds: [String]
        let reason: String

        if let highlight {
            let annotation = ManifestAnnotation(
                id: "native-highlight",
                atMs: 0,
                kind: "highlight",
                points: [
                    ManifestPoint(x: highlight.x, y: highlight.y),
                    ManifestPoint(x: highlight.maxX, y: highlight.maxY),
                ],
                coordinateSpace: "viewport-normalized",
                strokeWidth: 4,
                targetId: region.id
            )
            let event = ManifestTimelineEvent(
                id: "native-annotation",
                seq: 0,
                atMs: 0,
                kind: "annotation",
                targetId: region.id,
                payload: ManifestAnnotationPayload(
                    annotationId: annotation.id,
                    annotationKind: annotation.kind,
                    x: width * highlight.x,
                    y: height * highlight.y
                )
            )
            annotations = [annotation]
            timeline = [event]
            annotationIds = [annotation.id]
            eventIds = [event.id]
            reason = "annotation"
        } else {
            annotations = []
            timeline = []
            annotationIds = []
            eventIds = []
            reason = "mark"
        }

        let keyframe = ManifestKeyframe(
            id: "native-frame",
            atMs: 0,
            imagePath: posterFileName,
            targetIds: [region.id],
            annotationIds: annotationIds,
            transcriptSegmentIds: [],
            reason: reason,
            eventIds: eventIds
        )
        let manifest = Manifest(
            schemaVersion: "0.1.0",
            sessionId: sessionId,
            createdAt: createdAtText,
            page: ManifestPage(
                initialUrl: pageURL,
                title: "Native recording: \(note)"
            ),
            viewport: viewport,
            durationMs: durationMilliseconds,
            timeline: timeline,
            targets: [region],
            annotations: annotations,
            transcript: [],
            keyframes: [keyframe],
            artifacts: ManifestArtifacts(
                audio: audioFileName,
                video: movieFileName
            ),
            captureWarnings: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        return data
    }
}
