import CryptoKit
import Darwin
import Foundation

private struct StoredTranscriptionInstallation: Codable, Equatable {
    let schemaVersion: Int
    let artifactHashes: [String: String]
    let parakeetRelativePath: String
    let modelRelativePath: String
    let ffmpegRelativePath: String
    let installedAtMs: Int64
}

public actor TranscriptionProvisioner {
    private let paths: RelayPaths
    private let artifacts: TranscriptionArtifacts
    private let downloader: any TranscriptionDownloading
    private let extractor: any TranscriptionArchiveExtracting
    private let validator: any TranscriptionValidating
    private let fileManager: FileManager

    private let schemaVersion = 1
    private var provisioning = false

    public init(
        paths: RelayPaths,
        artifacts: TranscriptionArtifacts,
        downloader: any TranscriptionDownloading = URLSessionArtifactDownloader(),
        extractor: any TranscriptionArchiveExtracting = SystemTarArchiveExtractor(),
        validator: any TranscriptionValidating = CommandLineTranscriptionValidator(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.artifacts = artifacts
        self.downloader = downloader
        self.extractor = extractor
        self.validator = validator
        self.fileManager = fileManager
    }

    public func initialState() -> TranscriptionProvisioningState {
        if !provisioning {
            cleanupStaleStaging()
        }
        let values = (try? RelayEnvironment.readValues(paths: paths)) ?? [:]
        if let custom = customConfiguration(in: values) {
            return .custom(custom)
        }
        if let loaded = (try? loadCurrentInstallation()) ?? nil,
           isUsable(loaded) {
            return .ready(loaded)
        }
        return .idle
    }

    public func provision(
        progress: @escaping @Sendable (TranscriptionProvisioningState) -> Void
    ) async throws -> TranscriptionInstallation {
        guard !provisioning else {
            throw TranscriptionProvisioningError.installFailed(
                "Narration setup is already in progress."
            )
        }
        provisioning = true
        defer { provisioning = false }
        try Task.checkCancellation()
        progress(.checking)

        let values = try RelayEnvironment.readValues(paths: paths)
        if let custom = customConfiguration(in: values) {
            throw TranscriptionProvisioningError.customConfiguration(custom)
        }
        if let loaded = (try? loadCurrentInstallation()) ?? nil,
           isUsable(loaded) {
            progress(.ready(loaded))
            return loaded
        }

        try RelayEnvironment.prepareDirectories(paths)
        let installations = paths.transcriptionDirectory
            .appendingPathComponent("installations", isDirectory: true)
        try createDirectory(installations)
        cleanupStaleStaging()
        try checkDiskSpace()

        let staging = paths.transcriptionDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(staging)
        var movedToFinal = false
        defer {
            if !movedToFinal {
                try? fileManager.removeItem(at: staging)
            }
        }

        let downloads = staging.appendingPathComponent("downloads", isDirectory: true)
        try createDirectory(downloads)
        let total = artifacts.totalDownloadBytes
        var completed: Int64 = 0
        var downloaded: [String: URL] = [:]

        for artifact in artifacts.all {
            try Task.checkCancellation()
            let destination = downloads.appendingPathComponent(artifact.fileName)
            let stage = stageLabel(for: artifact)
            let before = completed
            try await downloadWithRetry(artifact, to: destination) { written, _ in
                let bounded = min(max(0, written), artifact.byteCount)
                progress(.downloading(
                    stage: stage,
                    completedBytes: before + bounded,
                    totalBytes: total
                ))
            }
            progress(.verifying(stage: "Verifying \(artifact.fileName)"))
            let digest = try await Self.sha256(at: destination)
            guard digest == artifact.sha256 else {
                throw TranscriptionProvisioningError.checksumMismatch(artifact.fileName)
            }
            completed += artifact.byteCount
            downloaded[artifact.id] = destination
        }

        try Task.checkCancellation()
        progress(.verifying(stage: "Unpacking narration tools"))
        guard let engineArchive = downloaded[artifacts.engine.id] else {
            throw TranscriptionProvisioningError.extractionFailed("The Parakeet engine archive is missing.")
        }
        guard let decoderArchive = downloaded[artifacts.decoder.id] else {
            throw TranscriptionProvisioningError.extractionFailed("The audio decoder archive is missing.")
        }
        guard let modelArchive = downloaded[artifacts.model.id] else {
            throw TranscriptionProvisioningError.extractionFailed("The narration model is missing.")
        }

        let engineBinary = try await installEngine(from: engineArchive, staging: staging)
        let ffmpegBinary = try await installDecoder(from: decoderArchive, staging: staging)
        let modelURL = try installModel(from: modelArchive, staging: staging)
        try writeNotices(staging: staging)
        removeQuarantine(from: staging.appendingPathComponent("engine", isDirectory: true))
        removeQuarantine(from: staging.appendingPathComponent("decoder", isDirectory: true))
        try? fileManager.removeItem(at: downloads)

        let staged = TranscriptionInstallation(
            parakeetBinary: engineBinary,
            model: modelURL,
            ffmpeg: ffmpegBinary,
            artifactHashes: artifactHashes()
        )
        progress(.verifying(stage: "Checking Parakeet and the audio decoder"))
        try await validator.validate(installation: staged)

        let stored = StoredTranscriptionInstallation(
            schemaVersion: schemaVersion,
            artifactHashes: artifactHashes(),
            parakeetRelativePath: relativePath(of: engineBinary, under: staging),
            modelRelativePath: relativePath(of: modelURL, under: staging),
            ffmpegRelativePath: relativePath(of: ffmpegBinary, under: staging),
            installedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        try writeStoredInstallation(stored, to: staging)

        try Task.checkCancellation()
        let finalName = "\(artifacts.installationKey)-\(UUID().uuidString.prefix(8))"
        let finalDirectory = installations.appendingPathComponent(finalName, isDirectory: true)
        try fileManager.moveItem(at: staging, to: finalDirectory)
        movedToFinal = true

        do {
            try swapCurrentLink(to: finalName)
        } catch {
            try? fileManager.removeItem(at: finalDirectory)
            throw error
        }
        cleanupOldInstallations(keeping: finalName)

        let installation = installationFromCurrent(stored: stored)
        progress(.ready(installation))
        return installation
    }

    private func customConfiguration(in values: [String: String]) -> String? {
        if let command = values[RelayEnvironment.transcriberCommandKey], !command.isEmpty {
            return "Using the existing \(RelayEnvironment.transcriberCommandKey) transcriber."
        }
        if let command = values[RelayEnvironment.asrCommandKey], !command.isEmpty {
            return "Using the existing \(RelayEnvironment.asrCommandKey) transcriber."
        }
        let bin = values[RelayEnvironment.parakeetBinKey] ?? ""
        let model = values[RelayEnvironment.parakeetModelKey] ?? ""
        let customBin = !bin.isEmpty && !RelayEnvironment.isTranscriptionPathOwned(bin, paths: paths)
        let customModel = !model.isEmpty && !RelayEnvironment.isTranscriptionPathOwned(model, paths: paths)
        if customBin || customModel {
            return "Using existing Parakeet paths from relay.env."
        }
        return nil
    }

    private func artifactHashes() -> [String: String] {
        Dictionary(uniqueKeysWithValues: artifacts.all.map { ($0.id, $0.sha256) })
    }

    private func stageLabel(for artifact: TranscriptionArtifact) -> String {
        switch artifact.kind {
        case .engineArchive:
            return "Downloading the Parakeet engine"
        case .model:
            return "Downloading the Parakeet model"
        case .decoderArchive:
            return "Downloading the audio decoder"
        }
    }

    private func downloadWithRetry(
        _ artifact: TranscriptionArtifact,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try await downloader.download(artifact, to: destination, progress: progress)
                return
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                attempt += 1
                if attempt >= 3 {
                    if let provisioning = error as? TranscriptionProvisioningError {
                        throw provisioning
                    }
                    throw TranscriptionProvisioningError.downloadFailed(
                        error.localizedDescription
                    )
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    private func installEngine(from archive: URL, staging: URL) async throws -> URL {
        let extracted = staging.appendingPathComponent("engine-extract", isDirectory: true)
        try await extractor.extract(archive: archive, to: extracted)
        guard let binary = findFile(named: "parakeet-cli", in: extracted) else {
            throw TranscriptionProvisioningError.extractionFailed(
                "The Parakeet archive did not contain parakeet-cli."
            )
        }
        try makeExecutable(binary)
        let relative = relativePath(of: binary, under: extracted)
        let destination = staging.appendingPathComponent("engine", isDirectory: true)
        try fileManager.moveItem(at: extracted, to: destination)
        return destination.appendingPathComponent(relative)
    }

    private func installDecoder(from archive: URL, staging: URL) async throws -> URL {
        let extracted = staging.appendingPathComponent("decoder-extract", isDirectory: true)
        try await extractor.extract(archive: archive, to: extracted)
        guard let binary = findFile(named: "ffmpeg", in: extracted) else {
            throw TranscriptionProvisioningError.extractionFailed(
                "The audio decoder archive did not contain ffmpeg."
            )
        }
        try makeExecutable(binary)
        let relative = relativePath(of: binary, under: extracted)
        let destination = staging.appendingPathComponent("decoder", isDirectory: true)
        try fileManager.moveItem(at: extracted, to: destination)
        return destination.appendingPathComponent(relative)
    }

    private func installModel(from archive: URL, staging: URL) throws -> URL {
        let directory = staging.appendingPathComponent("model", isDirectory: true)
        try createDirectory(directory)
        let destination = directory.appendingPathComponent(artifacts.model.fileName)
        try fileManager.moveItem(at: archive, to: destination)
        return destination
    }

    private func relativePath(of file: URL, under root: URL) -> String {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPrefix) else {
            return file.lastPathComponent
        }
        return String(file.path.dropFirst(rootPrefix.count))
    }

    private func findFile(named name: String, in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        for case let candidate as URL in enumerator where candidate.lastPathComponent == name {
            if let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
               values.isRegularFile == true {
                return candidate
            }
        }
        return nil
    }

    private func writeStoredInstallation(
        _ stored: StoredTranscriptionInstallation,
        to directory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        let url = directory.appendingPathComponent("installation.json", isDirectory: false)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeNotices(staging: URL) throws {
        let directory = staging.appendingPathComponent("licenses", isDirectory: true)
        try createDirectory(directory)
        let files: [(name: String, text: String)] = [
            ("NOTICE.txt", TranscriptionLicenseNotice.text),
            ("LICENSE-MIT-parakeet.cpp.txt", TranscriptionLicenseText.mitParakeetCPP),
            ("LICENSE-LGPL-2.1.txt", TranscriptionLicenseText.lgpl21),
            ("LICENSE-CC-BY-4.0.txt", TranscriptionLicenseText.ccBy40),
        ]
        for file in files {
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            try Data(file.text.utf8).write(to: url, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
    }

    private func makeExecutable(_ url: URL) throws {
        do {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw TranscriptionProvisioningError.installFailed(
                "Could not make \(url.lastPathComponent) executable: \(error.localizedDescription)"
            )
        }
    }

    private func removeQuarantine(from directory: URL) {
        removeQuarantineAttribute(at: directory)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }
        for case let url as URL in enumerator {
            removeQuarantineAttribute(at: url)
        }
    }

    private func removeQuarantineAttribute(at url: URL) {
        url.path.withCString { path in
            _ = removexattr(path, "com.apple.quarantine", 0)
        }
    }

    private func checkDiskSpace() throws {
        let key: URLResourceKey = .volumeAvailableCapacityForImportantUsageKey
        guard let values = try? paths.transcriptionDirectory.resourceValues(forKeys: [key]),
              let available = values.volumeAvailableCapacityForImportantUsage,
              available > 0
        else {
            return
        }
        let required = artifacts.totalDownloadBytes * 2 + Int64(64 * 1024 * 1024)
        guard available >= required else {
            throw TranscriptionProvisioningError.insufficientDiskSpace(
                required: required,
                available: available
            )
        }
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw TranscriptionProvisioningError.installFailed(
                "Could not create \(url.path): \(error.localizedDescription)"
            )
        }
    }

    private func swapCurrentLink(to finalName: String) throws {
        let current = paths.transcriptionDirectory.appendingPathComponent("current", isDirectory: true)
        if fileManager.fileExists(atPath: current.path),
           (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) == nil {
            throw TranscriptionProvisioningError.installFailed(
                "\(current.path) exists and is not a Highlite-managed link."
            )
        }
        let temporary = paths.transcriptionDirectory
            .appendingPathComponent(".current-\(UUID().uuidString)", isDirectory: false)
        try fileManager.createSymbolicLink(
            atPath: temporary.path,
            withDestinationPath: "installations/\(finalName)"
        )
        let result = temporary.path.withCString { source in
            current.path.withCString { destination in
                rename(source, destination)
            }
        }
        guard result == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw TranscriptionProvisioningError.installFailed(
                "Could not activate the new narration installation."
            )
        }
    }

    private func cleanupStaleStaging() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.transcriptionDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".staging-") || name.hasPrefix(".current-") {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func cleanupOldInstallations(keeping currentName: String) {
        let directory = paths.transcriptionDirectory.appendingPathComponent("installations", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent != currentName {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func loadCurrentInstallation() throws -> TranscriptionInstallation? {
        let current = paths.transcriptionDirectory.appendingPathComponent("current", isDirectory: true)
        guard fileManager.fileExists(atPath: current.path) else {
            return nil
        }
        let target = try fileManager.destinationOfSymbolicLink(atPath: current.path)
        let storageRoot = paths.transcriptionDirectory
            .appendingPathComponent(target, isDirectory: true)
            .standardizedFileURL
        let data = try Data(contentsOf: storageRoot.appendingPathComponent("installation.json"))
        let stored = try JSONDecoder().decode(StoredTranscriptionInstallation.self, from: data)
        guard stored.schemaVersion == schemaVersion,
              stored.artifactHashes == artifactHashes()
        else {
            return nil
        }
        let installation = TranscriptionInstallation(
            parakeetBinary: current.appendingPathComponent(stored.parakeetRelativePath),
            model: current.appendingPathComponent(stored.modelRelativePath),
            ffmpeg: current.appendingPathComponent(stored.ffmpegRelativePath),
            artifactHashes: stored.artifactHashes,
            installedAt: Date(timeIntervalSince1970: Double(stored.installedAtMs) / 1_000)
        )
        guard isUsable(installation) else {
            return nil
        }
        return installation
    }

    private func installationFromCurrent(
        stored: StoredTranscriptionInstallation
    ) -> TranscriptionInstallation {
        let current = paths.transcriptionDirectory.appendingPathComponent("current", isDirectory: true)
        return TranscriptionInstallation(
            parakeetBinary: current.appendingPathComponent(stored.parakeetRelativePath),
            model: current.appendingPathComponent(stored.modelRelativePath),
            ffmpeg: current.appendingPathComponent(stored.ffmpegRelativePath),
            artifactHashes: stored.artifactHashes,
            installedAt: Date(timeIntervalSince1970: Double(stored.installedAtMs) / 1_000)
        )
    }

    private func isUsable(_ installation: TranscriptionInstallation) -> Bool {
        guard fileManager.isExecutableFile(atPath: installation.parakeetBinary.path),
              fileManager.isExecutableFile(atPath: installation.ffmpeg.path),
              let attributes = try? fileManager.attributesOfItem(
                  atPath: installation.model.path
              ),
              let modelSize = attributes[.size] as? NSNumber
        else {
            return false
        }
        return modelSize.int64Value == artifacts.model.byteCount
    }

    private static func sha256(at url: URL) async throws -> String {
        let cancellation = ProvisioningCancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while true {
                    if cancellation.isCancelled {
                        throw CancellationError()
                    }
                    let data = try handle.read(upToCount: 1 << 20) ?? Data()
                    if data.isEmpty {
                        break
                    }
                    hasher.update(data: data)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class ProvisioningCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
