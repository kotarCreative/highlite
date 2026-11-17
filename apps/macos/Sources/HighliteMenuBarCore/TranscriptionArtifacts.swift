import Foundation
import Darwin

public enum TranscriptionProvisioningError: LocalizedError, Equatable, Sendable {
    case unsupportedArchitecture(String)
    case insufficientDiskSpace(required: Int64, available: Int64)
    case downloadFailed(String)
    case checksumMismatch(String)
    case extractionFailed(String)
    case validationFailed(String)
    case installFailed(String)
    case customConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let architecture):
            return "Narration setup does not support this Mac architecture (\(architecture))."
        case .insufficientDiskSpace(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            return "Narration setup needs about \(formatter.string(fromByteCount: required)) free, but only \(formatter.string(fromByteCount: available)) is available."
        case .downloadFailed(let message):
            return "The narration download failed: \(message)"
        case .checksumMismatch(let name):
            return "The downloaded \(name) did not match its pinned checksum, so it was discarded."
        case .extractionFailed(let message):
            return "The narration archive could not be unpacked: \(message)"
        case .validationFailed(let message):
            return "The narration tools could not be verified: \(message)"
        case .installFailed(let message):
            return "Narration setup could not be installed: \(message)"
        case .customConfiguration(let message):
            return message
        }
    }
}

public enum TranscriptionArtifactKind: String, Codable, Equatable, Sendable {
    case engineArchive
    case model
    case decoderArchive
}

public struct TranscriptionArtifact: Equatable, Sendable {
    public let kind: TranscriptionArtifactKind
    public let id: String
    public let url: URL
    public let sha256: String
    public let byteCount: Int64
    public let fileName: String

    public init(
        kind: TranscriptionArtifactKind,
        id: String,
        url: URL,
        sha256: String,
        byteCount: Int64,
        fileName: String
    ) {
        self.kind = kind
        self.id = id
        self.url = url
        self.sha256 = sha256.lowercased()
        self.byteCount = byteCount
        self.fileName = fileName
    }
}

public enum TranscriptionArchitecture {
    public static func host() throws -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            throw TranscriptionProvisioningError.unsupportedArchitecture("unknown")
        }
        var machine = [CChar](repeating: 0, count: size)
        let status = machine.withUnsafeMutableBytes { buffer in
            sysctlbyname("hw.machine", buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else {
            throw TranscriptionProvisioningError.unsupportedArchitecture("unknown")
        }
        return String(cString: machine)
    }

    public static func normalized(_ architecture: String) throws -> String {
        switch architecture {
        case "arm64", "aarch64":
            return "arm64"
        case "x86_64", "x86-64", "amd64":
            return "x86_64"
        default:
            throw TranscriptionProvisioningError.unsupportedArchitecture(architecture)
        }
    }
}

public struct TranscriptionArtifacts: Equatable, Sendable {
    public static let engineVersion = "parakeet.cpp v0.6.1"
    public static let modelVersion = "NVIDIA Parakeet TDT-CTC 110M Q8_0"
    public static let decoderVersion = "FFmpeg 7.1 universal2 (LGPL)"

    public let architecture: String
    public let engine: TranscriptionArtifact
    public let model: TranscriptionArtifact
    public let decoder: TranscriptionArtifact

    public init(
        architecture: String,
        engine: TranscriptionArtifact,
        model: TranscriptionArtifact,
        decoder: TranscriptionArtifact
    ) {
        self.architecture = architecture
        self.engine = engine
        self.model = model
        self.decoder = decoder
    }

    public var all: [TranscriptionArtifact] {
        [engine, model, decoder]
    }

    public var totalDownloadBytes: Int64 {
        all.reduce(0) { $0 + $1.byteCount }
    }

    public var installationKey: String {
        let raw = "\(engine.id)-\(model.id)-\(decoder.id)"
        let safe = raw.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "." {
                return character
            }
            return "-"
        }
        return "install-\(String(safe).prefix(96))"
    }

    public static func current(architecture: String? = nil) throws -> TranscriptionArtifacts {
        let requested: String
        if let architecture {
            requested = architecture
        } else {
            requested = try TranscriptionArchitecture.host()
        }
        let host = try TranscriptionArchitecture.normalized(requested)
        let engine: TranscriptionArtifact
        switch host {
        case "arm64":
            engine = TranscriptionArtifact(
                kind: .engineArchive,
                id: "parakeet-0.6.1-macos-metal-arm64",
                url: URL(string: "https://github.com/mudler/parakeet.cpp/releases/download/v0.6.1/parakeet-v0.6.1-bin-macos-metal-arm64.tar.gz")!,
                sha256: "bc97b5e6253e928d1127f48f08242324317495ef8708e31db1e09b9537d1bb74",
                byteCount: 2_587_801,
                fileName: "parakeet-v0.6.1-bin-macos-metal-arm64.tar.gz"
            )
        default:
            engine = TranscriptionArtifact(
                kind: .engineArchive,
                id: "parakeet-0.6.1-macos-cpu-x64",
                url: URL(string: "https://github.com/mudler/parakeet.cpp/releases/download/v0.6.1/parakeet-v0.6.1-bin-macos-cpu-x64.tar.gz")!,
                sha256: "82392069ea091c896dcf86fb5d86f20d107c71f6bad4b9e79a114523d98fb643",
                byteCount: 2_753_061,
                fileName: "parakeet-v0.6.1-bin-macos-cpu-x64.tar.gz"
            )
        }

        return TranscriptionArtifacts(
            architecture: host,
            engine: engine,
            model: TranscriptionArtifact(
                kind: .model,
                id: "parakeet-tdt-ctc-110m-q8_0",
                url: URL(string: "https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/07a08a3a405d20c5434b9a1442f6e6cf571f57ad/tdt_ctc-110m-q8_0.gguf")!,
                sha256: "614feee3a990cf0e672b0314f4da0c80ae8da9094507f5ccb7c42e43b5fc5a12",
                byteCount: 177_796_224,
                fileName: "tdt_ctc-110m-q8_0.gguf"
            ),
            decoder: TranscriptionArtifact(
                kind: .decoderArchive,
                id: "ffmpeg-7.1-r2-macos-lgpl-universal2",
                url: URL(string: "https://github.com/EricEngineering/ffmpeg-macos-lgpl/releases/download/ffmpeg-7.1-r2/ffmpeg-macos-lgpl-universal2.tar.gz")!,
                sha256: "c725431e0b073bad12619d53c6d759b399ee84450790a8d681ecbb4066bf1194",
                byteCount: 45_509_759,
                fileName: "ffmpeg-macos-lgpl-universal2.tar.gz"
            )
        )
    }
}

public struct TranscriptionInstallation: Equatable, Sendable {
    public let parakeetBinary: URL
    public let model: URL
    public let ffmpeg: URL
    public let artifactHashes: [String: String]
    public let installedAt: Date

    public init(
        parakeetBinary: URL,
        model: URL,
        ffmpeg: URL,
        artifactHashes: [String: String],
        installedAt: Date = Date()
    ) {
        self.parakeetBinary = parakeetBinary
        self.model = model
        self.ffmpeg = ffmpeg
        self.artifactHashes = artifactHashes
        self.installedAt = installedAt
    }
}

public enum TranscriptionProvisioningState: Equatable, Sendable {
    case idle
    case checking
    case custom(String)
    case downloading(stage: String, completedBytes: Int64, totalBytes: Int64)
    case verifying(stage: String)
    case ready(TranscriptionInstallation)
    case failed(String)

    public var fraction: Double? {
        guard case .downloading(_, let completed, let total) = self, total > 0 else {
            return nil
        }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public enum TranscriptionLicenseNotice {
    public static let text = """
    Highlite narration setup

    Engine: parakeet.cpp v0.6.1, Copyright (c) 2026 the parakeet.cpp authors.
    Licensed under the MIT License. The release archive also ships its own
    LICENSE file, which Highlite keeps next to the installed binaries.
    https://github.com/mudler/parakeet.cpp

    Model: NVIDIA Parakeet TDT-CTC 110M (English), by NVIDIA Corporation.
    Licensed under CC-BY-4.0. The model was converted to GGUF and quantized to
    Q8_0 by the mudler/parakeet-cpp-gguf project; no training or fine-tuning
    was done by that conversion.
    https://huggingface.co/nvidia/parakeet-tdt_ctc-110m
    https://huggingface.co/mudler/parakeet-cpp-gguf

    Audio decoder: FFmpeg 7.1 universal2, a static LGPL build from
    EricEngineering/ffmpeg-macos-lgpl (no GPL or nonfree components).
    FFmpeg is licensed under the GNU LGPL v2.1 or later. The build scripts and
    the corresponding FFmpeg sources are published by that project and by the
    FFmpeg project.
    https://github.com/EricEngineering/ffmpeg-macos-lgpl
    https://ffmpeg.org/legal.html

    Full license texts are installed in this folder:
    LICENSE-MIT-parakeet.cpp.txt, LICENSE-LGPL-2.1.txt, LICENSE-CC-BY-4.0.txt

    The model and tools run locally. No capture audio is sent to these
    download providers.
    """
}
