import Foundation

/// A self-contained native screen recording ready to POST to the relay's local
/// ingest endpoint.
///
/// The archive is additive to the still-capture contract: `manifest.json`,
/// `poster.png`, optional `moment-NNN.png` frames, `recording.mp4`, and
/// optionally `recording.<audio-extension>`. The manifest names the movie and
/// audio through `artifacts.video` and `artifacts.audio`; the canonical compiler
/// treats the poster as the first keyframe image exactly as it does for a still
/// capture, and each captured moment as an additional keyframe.
public struct NativeRecordingBundle: Sendable {
    public let sessionId: String
    public let createdAt: Date
    public let note: String
    public let imageWidth: Int
    public let imageHeight: Int
    public let durationMilliseconds: Int
    public let hasMicrophoneAudio: Bool
    /// Number of keyframes in the manifest: the poster plus captured moments.
    public let keyframeCount: Int
    public let manifestJSON: Data
    public let archive: Data
}

/// One reviewed moment from a recording. The caller extracts a PNG from the
/// movie and supplies normalized annotations for that exact timestamp. The
/// bundle builder assigns file names, annotation ids, and manifest ordering.
public struct NativeRecordingMoment: Sendable {
    public let atMs: Int
    public let pngData: Data
    public let annotations: [NativeCaptureAnnotation]

    public init(
        atMs: Int,
        pngData: Data,
        annotations: [NativeCaptureAnnotation] = []
    ) {
        self.atMs = atMs
        self.pngData = pngData
        self.annotations = annotations
    }
}

public enum NativeRecordingBundleError: LocalizedError, Equatable {
    case invalidPoster
    case invalidMovie
    case invalidDuration
    case emptyNote
    case noteTooLong
    case invalidHighlight
    case invalidAnnotation
    case invalidMoment
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
        case .invalidAnnotation:
            return "Keep every annotation inside the frame and make it large enough to see."
        case .invalidMoment:
            return "Each captured frame must be a readable image from inside the recording, at least half a second apart."
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
    /// The compiler's default keyframe cap is twelve, including the poster.
    public static let maximumMomentCount = 11
    /// Matches the compiler's default duplicate-frame gap so every reviewed
    /// moment survives compilation instead of being merged into its neighbour.
    public static let minimumMomentGapMilliseconds = 500

    /// The compiler budgets six keyframes up to 20 seconds, then one more per
    /// 20 seconds, capped at twelve. Keep the poster inside that budget so a
    /// reviewed moment is not silently dropped at compile time.
    public static func maximumMoments(forDurationMilliseconds durationMilliseconds: Int) -> Int {
        let extra = max(0, durationMilliseconds - 20_000) / 20_000
        let budget = min(12, 6 + extra)
        return max(0, min(maximumMomentCount, budget - 1))
    }

    private static let pageURL = "highlite://native-capture/recording"

    /// Builds a recording with the full browser annotation set. The poster is
    /// the first keyframe at 0 ms; each reviewed moment becomes an additional
    /// keyframe with its own extracted PNG and normalized annotations.
    public static func build(
        movieData: Data,
        posterPNGData: Data,
        audioData: Data? = nil,
        audioFileExtension: String = "m4a",
        note: String,
        annotations: [NativeCaptureAnnotation] = [],
        moments: [NativeRecordingMoment] = [],
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

        try validateAnnotations(
            annotations,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let sortedMoments = try validatedMoments(
            moments,
            durationMilliseconds: durationMilliseconds,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )

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

        let frames = makeFrames(
            posterPNGData: posterPNGData,
            annotations: annotations,
            moments: sortedMoments
        )
        let manifestData = try makeManifest(
            sessionId: identifier,
            createdAt: createdAt,
            note: trimmedNote,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            durationMilliseconds: durationMilliseconds,
            frames: frames,
            audioFileName: audioFileName
        )

        var entries = [
            StoredZip.Entry(name: "manifest.json", data: manifestData),
            StoredZip.Entry(name: posterFileName, data: posterPNGData),
        ]
        for frame in frames.dropFirst() {
            entries.append(StoredZip.Entry(name: frame.imagePath, data: frame.pngData))
        }
        entries.append(StoredZip.Entry(name: movieFileName, data: movieData))
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
            keyframeCount: frames.count,
            manifestJSON: manifestData,
            archive: archive
        )
    }

    /// Backward-compatible poster-highlight entry point. A lone highlight keeps
    /// the canonical `native-highlight` annotation and `native-annotation` event
    /// ids, so existing recording manifests stay byte-compatible.
    public static func build(
        movieData: Data,
        posterPNGData: Data,
        audioData: Data? = nil,
        audioFileExtension: String = "m4a",
        note: String,
        highlight: NativeCaptureRect?,
        durationMilliseconds: Int,
        createdAt: Date = Date(),
        sessionId: String? = nil
    ) throws -> NativeRecordingBundle {
        let annotations = highlight.map { rect in
            [
                NativeCaptureAnnotation(
                    kind: .highlight,
                    points: [
                        NativeCapturePoint(x: rect.x, y: rect.y),
                        NativeCapturePoint(x: rect.maxX, y: rect.maxY),
                    ]
                )
            ]
        } ?? []
        do {
            return try build(
                movieData: movieData,
                posterPNGData: posterPNGData,
                audioData: audioData,
                audioFileExtension: audioFileExtension,
                note: note,
                annotations: annotations,
                moments: [],
                durationMilliseconds: durationMilliseconds,
                createdAt: createdAt,
                sessionId: sessionId
            )
        } catch let error as NativeRecordingBundleError {
            switch error {
            case .invalidAnnotation:
                throw NativeRecordingBundleError.invalidHighlight
            default:
                throw error
            }
        } catch {
            throw error
        }
    }

    private struct FrameSpec {
        let atMs: Int
        let imagePath: String
        let pngData: Data
        let annotations: [NativeCaptureAnnotation]
    }

    private static func validateAnnotations(
        _ annotations: [NativeCaptureAnnotation],
        imageWidth: Int,
        imageHeight: Int
    ) throws {
        guard !annotations.isEmpty else { return }
        guard annotations.count <= NativeCaptureAnnotationLimits.maximumAnnotations else {
            throw NativeRecordingBundleError.invalidAnnotation
        }
        do {
            try NativeCaptureBundleBuilder.validate(
                annotations,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        } catch {
            throw NativeRecordingBundleError.invalidAnnotation
        }
    }

    private static func validatedMoments(
        _ moments: [NativeRecordingMoment],
        durationMilliseconds: Int,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> [NativeRecordingMoment] {
        guard moments.count <= maximumMoments(forDurationMilliseconds: durationMilliseconds) else {
            throw NativeRecordingBundleError.invalidMoment
        }
        let sorted = moments.sorted { $0.atMs < $1.atMs }
        // The poster occupies the 0 ms keyframe, so the first captured moment
        // must clear the same gap or the compiler can merge it into the poster.
        var previousAtMs = 0
        for moment in sorted {
            guard moment.atMs > 0,
                  moment.atMs <= durationMilliseconds
            else {
                throw NativeRecordingBundleError.invalidMoment
            }
            if moment.atMs - previousAtMs < minimumMomentGapMilliseconds {
                throw NativeRecordingBundleError.invalidMoment
            }
            let dimensions: (Int, Int)
            do {
                dimensions = try NativeCaptureBundleBuilder.imageDimensions(in: moment.pngData)
            } catch {
                throw NativeRecordingBundleError.invalidMoment
            }
            guard dimensions == (imageWidth, imageHeight) else {
                throw NativeRecordingBundleError.invalidMoment
            }
            try validateAnnotations(
                moment.annotations,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            previousAtMs = moment.atMs
        }
        return sorted
    }

    private static func makeFrames(
        posterPNGData: Data,
        annotations: [NativeCaptureAnnotation],
        moments: [NativeRecordingMoment]
    ) -> [FrameSpec] {
        var frames = [
            FrameSpec(
                atMs: 0,
                imagePath: posterFileName,
                pngData: posterPNGData,
                annotations: annotations
            )
        ]
        for (index, moment) in moments.enumerated() {
            frames.append(
                FrameSpec(
                    atMs: moment.atMs,
                    imagePath: String(format: "moment-%03d.png", index + 1),
                    pngData: moment.pngData,
                    annotations: moment.annotations
                )
            )
        }
        return frames
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
        frames: [FrameSpec],
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

        // Review annotations belong to the frame they were drawn on. The
        // compiler treats a missing fade as "visible forever", so multi-frame
        // recordings give annotations a 1 ms fade to stop them bleeding into
        // every later keyframe. Single-frame manifests omit the fields to stay
        // byte-compatible with the original recording contract.
        let usesPerFrameFade = frames.count > 1
        var usedAnnotationIds: Set<String> = []
        var usedEventIds: Set<String> = []
        var sequence = 0
        var annotations: [ManifestAnnotation] = []
        var timeline: [ManifestTimelineEvent] = []
        var keyframes: [ManifestKeyframe] = []

        for (frameIndex, frame) in frames.enumerated() {
            var annotationIds: [String] = []
            var eventIds: [String] = []
            for annotation in frame.annotations {
                let annotationId = nextAnnotationId(
                    kind: annotation.kind,
                    used: &usedAnnotationIds
                )
                annotations.append(
                    ManifestAnnotation(
                        id: annotationId,
                        atMs: frame.atMs,
                        kind: annotation.kind.rawValue,
                        points: annotation.points.map {
                            ManifestPoint(x: $0.x, y: $0.y)
                        },
                        coordinateSpace: "viewport-normalized",
                        strokeWidth: NativeCaptureAnnotationLimits.strokeWidth,
                        fadeAfterMs: usesPerFrameFade ? 0 : nil,
                        fadeDurationMs: usesPerFrameFade ? 1 : nil,
                        targetId: region.id
                    )
                )

                let origin = annotation.points[0]
                let eventId = nextEventId(used: &usedEventIds)
                timeline.append(
                    ManifestTimelineEvent(
                        id: eventId,
                        seq: sequence,
                        atMs: frame.atMs,
                        kind: "annotation",
                        targetId: region.id,
                        payload: ManifestAnnotationPayload(
                            annotationId: annotationId,
                            annotationKind: annotation.kind.rawValue,
                            x: width * origin.x,
                            y: height * origin.y
                        )
                    )
                )
                annotationIds.append(annotationId)
                eventIds.append(eventId)
                sequence += 1
            }

            keyframes.append(
                ManifestKeyframe(
                    id: frameIndex == 0 ? "native-frame" : "native-frame-\(frameIndex + 1)",
                    atMs: frame.atMs,
                    imagePath: frame.imagePath,
                    targetIds: [region.id],
                    annotationIds: annotationIds,
                    transcriptSegmentIds: [],
                    reason: annotationIds.isEmpty ? "mark" : "annotation",
                    eventIds: eventIds
                )
            )
        }
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
            keyframes: keyframes,
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

    /// First use of each tool keeps the legacy base id (`native-highlight`,
    /// `native-circle`, …); later uses append an occurrence suffix.
    private static func nextAnnotationId(
        kind: NativeCaptureAnnotationKind,
        used: inout Set<String>
    ) -> String {
        let base = "native-\(kind.rawValue)"
        var candidate = base
        var occurrence = 1
        while used.contains(candidate) {
            occurrence += 1
            candidate = "\(base)-\(occurrence)"
        }
        used.insert(candidate)
        return candidate
    }

    /// The first annotation keeps the canonical `native-annotation` event id so
    /// a single poster highlight remains byte-compatible with earlier saves.
    private static func nextEventId(used: inout Set<String>) -> String {
        var candidate = "native-annotation"
        var occurrence = 1
        while used.contains(candidate) {
            occurrence += 1
            candidate = "native-annotation-\(occurrence)"
        }
        used.insert(candidate)
        return candidate
    }
}
