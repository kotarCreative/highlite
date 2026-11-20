import Foundation

/// A normalized rectangle drawn by the user over a native still capture.
///
/// Coordinates use the capture image's top-left origin and are relative to the
/// image size, matching the browser capture's `viewport-normalized` space.
public struct NativeCaptureRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// A self-contained still capture ready to POST to the relay's local ingest
/// endpoint. The archive holds the canonical `manifest.json` and a PNG.
public struct NativeCaptureBundle: Sendable {
    public let sessionId: String
    public let createdAt: Date
    public let note: String
    public let imageWidth: Int
    public let imageHeight: Int
    public let manifestJSON: Data
    public let archive: Data
}

public enum NativeCaptureBundleError: LocalizedError, Equatable {
    case invalidImage
    case emptyNote
    case noteTooLong
    case invalidHighlight
    case invalidSessionId
    case archiveTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The capture is not a readable PNG image."
        case .emptyNote:
            return "Add a short note before saving the capture."
        case .noteTooLong:
            return "Keep the note under 2,000 characters."
        case .invalidHighlight:
            return "Draw a highlight rectangle on the capture."
        case .invalidSessionId:
            return "The capture session identifier is not valid."
        case .archiveTooLarge:
            return "The capture is too large to package for the relay."
        }
    }
}

/// Builds the exact capture shape the canonical compiler and relay accept,
/// without depending on AppKit or the relay client. All inputs are explicit so
/// the same call can be tested with a fixture image and a fixed timestamp.
public enum NativeCaptureBundleBuilder {
    public static let maximumNoteLength = 2_000
    private static let pageURL = "highlite://native-capture/still"

    public static func build(
        pngData: Data,
        note: String,
        highlight: NativeCaptureRect,
        createdAt: Date = Date(),
        sessionId: String? = nil
    ) throws -> NativeCaptureBundle {
        let (imageWidth, imageHeight) = try imageDimensions(in: pngData)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else {
            throw NativeCaptureBundleError.emptyNote
        }
        guard trimmedNote.count <= maximumNoteLength else {
            throw NativeCaptureBundleError.noteTooLong
        }
        try validate(highlight, imageWidth: imageWidth, imageHeight: imageHeight)

        let identifier = sessionId ?? defaultSessionId(createdAt: createdAt)
        guard isValidSessionId(identifier) else {
            throw NativeCaptureBundleError.invalidSessionId
        }

        let manifestData = try makeManifest(
            sessionId: identifier,
            createdAt: createdAt,
            note: trimmedNote,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            highlight: highlight
        )
        let archive = try StoredZip.archive(entries: [
            StoredZip.Entry(name: "manifest.json", data: manifestData),
            StoredZip.Entry(name: "capture.png", data: pngData),
        ])

        return NativeCaptureBundle(
            sessionId: identifier,
            createdAt: createdAt,
            note: trimmedNote,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            manifestJSON: manifestData,
            archive: archive
        )
    }

    /// Reads the dimensions from a PNG's IHDR chunk. The relay's compiler is the
    /// authority on whether the image decodes; this only rejects obviously
    /// malformed input before building the manifest.
    public static func imageDimensions(in pngData: Data) throws -> (width: Int, height: Int) {
        let bytes = [UInt8](pngData)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 24, Array(bytes[0..<8]) == signature,
              bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52
        else {
            throw NativeCaptureBundleError.invalidImage
        }
        let width = readBigEndianUInt32(bytes, at: 16)
        let height = readBigEndianUInt32(bytes, at: 20)
        guard width > 0, height > 0,
              width <= 100_000, height <= 100_000
        else {
            throw NativeCaptureBundleError.invalidImage
        }
        return (width, height)
    }

    static func validate(
        _ highlight: NativeCaptureRect,
        imageWidth: Int,
        imageHeight: Int
    ) throws {
        let epsilon = 1e-9
        guard highlight.x.isFinite, highlight.y.isFinite,
              highlight.width.isFinite, highlight.height.isFinite,
              highlight.x >= 0, highlight.y >= 0,
              highlight.width > 0, highlight.height > 0,
              highlight.maxX <= 1 + epsilon, highlight.maxY <= 1 + epsilon,
              highlight.width * Double(imageWidth) >= 1,
              highlight.height * Double(imageHeight) >= 1
        else {
            throw NativeCaptureBundleError.invalidHighlight
        }
    }

    static func defaultSessionId(createdAt: Date) -> String {
        let milliseconds = Int64((createdAt.timeIntervalSince1970 * 1_000).rounded())
        return "native-\(milliseconds)-\(UUID().uuidString.lowercased())"
    }

    static func isValidSessionId(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (65...90).contains(first) || (97...122).contains(first) || (48...57).contains(first),
              value.utf8.count <= 128,
              !value.contains("..")
        else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (65...90).contains(byte)
                || (97...122).contains(byte)
                || (48...57).contains(byte)
                || byte == 0x2D
                || byte == 0x5F
                || byte == 0x2E
        }
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> Int {
        (Int(bytes[offset]) << 24)
            | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8)
            | Int(bytes[offset + 3])
    }

    private static func makeManifest(
        sessionId: String,
        createdAt: Date,
        note: String,
        imageWidth: Int,
        imageHeight: Int,
        highlight: NativeCaptureRect
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
            metadata: ["source": "macos-native", "captureMode": "still"]
        )
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
        let keyframe = ManifestKeyframe(
            id: "native-frame",
            atMs: 0,
            imagePath: "capture.png",
            targetIds: [region.id],
            annotationIds: [annotation.id],
            transcriptSegmentIds: [],
            reason: "annotation",
            eventIds: [event.id]
        )
        let manifest = Manifest(
            schemaVersion: "0.1.0",
            sessionId: sessionId,
            createdAt: createdAtText,
            page: ManifestPage(
                initialUrl: pageURL,
                title: "Native capture: \(note)"
            ),
            viewport: viewport,
            durationMs: 0,
            timeline: [event],
            targets: [region],
            annotations: [annotation],
            transcript: [],
            keyframes: [keyframe],
            artifacts: ManifestArtifacts(),
            captureWarnings: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        return data
    }
}

// MARK: - Manifest shape

struct Manifest: Encodable {
    let schemaVersion: String
    let sessionId: String
    let createdAt: String
    let page: ManifestPage
    let viewport: ManifestRect
    let durationMs: Int
    let timeline: [ManifestTimelineEvent]
    let targets: [ManifestTarget]
    let annotations: [ManifestAnnotation]
    let transcript: [ManifestTranscriptSegment]
    let keyframes: [ManifestKeyframe]
    let artifacts: ManifestArtifacts
    let captureWarnings: [String]
}

struct ManifestPage: Encodable {
    let initialUrl: String
    let title: String
}

struct ManifestRect: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct ManifestPoint: Encodable {
    let x: Double
    let y: Double
}

struct ManifestTimelineEvent: Encodable {
    let id: String
    let seq: Int
    let atMs: Int
    let kind: String
    let targetId: String
    let payload: ManifestAnnotationPayload
}

struct ManifestAnnotationPayload: Encodable {
    let annotationId: String
    let annotationKind: String
    let x: Double
    let y: Double
}

struct ManifestTarget: Encodable {
    let id: String
    let tag: String
    let role: String
    let label: String
    let textExcerpt: String
    let selector: String?
    let rect: ManifestRect
    let pageUrl: String
    let metadata: [String: String]
}

struct ManifestAnnotation: Encodable {
    let id: String
    let atMs: Int
    let kind: String
    let points: [ManifestPoint]
    let coordinateSpace: String
    let strokeWidth: Double
    let targetId: String
}

struct ManifestTranscriptSegment: Encodable {}

struct ManifestKeyframe: Encodable {
    let id: String
    let atMs: Int
    let imagePath: String
    let targetIds: [String]
    let annotationIds: [String]
    let transcriptSegmentIds: [String]
    let reason: String
    let eventIds: [String]
}

struct ManifestArtifacts: Encodable {
    var audio: String?
    var video: String?
    var contactSheet: String?

    init(audio: String? = nil, video: String? = nil, contactSheet: String? = nil) {
        self.audio = audio
        self.video = video
        self.contactSheet = contactSheet
    }
}

// MARK: - ZIP

/// Minimal stored (uncompressed) ZIP writer for the two-file capture archive.
/// PNG is already compressed, so deflating would add code and dependencies for
/// little benefit. The canonical relay reads this with the standard `zip` crate.
enum StoredZip {
    struct Entry {
        let name: String
        let data: Data
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endRecordSignature: UInt32 = 0x0605_4B50
    private static let dosDate: UInt16 = 0x0021 // 1980-01-01

    static func archive(entries: [Entry]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw NativeCaptureBundleError.archiveTooLarge
        }

        var archive = Data()
        var centralRecords: [Data] = []

        for entry in entries {
            let name = Data(entry.name.utf8)
            guard !name.isEmpty, name.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max)
            else {
                throw NativeCaptureBundleError.archiveTooLarge
            }
            guard archive.count <= Int(UInt32.max) else {
                throw NativeCaptureBundleError.archiveTooLarge
            }
            let checksum = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            archive.appendLE32(localHeaderSignature)
            archive.appendLE16(20)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE16(dosDate)
            archive.appendLE32(checksum)
            archive.appendLE32(size)
            archive.appendLE32(size)
            archive.appendLE16(UInt16(name.count))
            archive.appendLE16(0)
            archive.append(contentsOf: name)
            archive.append(entry.data)
            guard archive.count <= Int(UInt32.max) else {
                throw NativeCaptureBundleError.archiveTooLarge
            }

            var central = Data()
            central.appendLE32(centralHeaderSignature)
            central.appendLE16(20)
            central.appendLE16(20)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(dosDate)
            central.appendLE32(checksum)
            central.appendLE32(size)
            central.appendLE32(size)
            central.appendLE16(UInt16(name.count))
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE32(0)
            central.appendLE32(offset)
            central.append(contentsOf: name)
            centralRecords.append(central)
        }

        guard archive.count <= Int(UInt32.max) else {
            throw NativeCaptureBundleError.archiveTooLarge
        }
        let centralOffset = UInt32(archive.count)
        for record in centralRecords {
            archive.append(record)
        }
        guard archive.count <= Int(UInt32.max) else {
            throw NativeCaptureBundleError.archiveTooLarge
        }
        let centralSize = UInt32(archive.count) - centralOffset
        let count = UInt16(entries.count)

        archive.appendLE32(endRecordSignature)
        archive.appendLE16(0)
        archive.appendLE16(0)
        archive.appendLE16(count)
        archive.appendLE16(count)
        archive.appendLE32(centralSize)
        archive.appendLE32(centralOffset)
        archive.appendLE16(0)
        return archive
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1
                ? 0xEDB8_8320 ^ (value >> 1)
                : value >> 1
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            checksum = crcTable[Int((checksum ^ UInt32(byte)) & 0xFF)] ^ (checksum >> 8)
        }
        return checksum ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
