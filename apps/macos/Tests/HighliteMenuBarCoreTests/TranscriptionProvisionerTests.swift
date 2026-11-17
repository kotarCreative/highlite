import CryptoKit
import Foundation
import XCTest
@testable import HighliteMenuBarCore

private actor FakeTranscriptionDownloader: TranscriptionDownloading {
    private let payloads: [String: Data]
    private var failures: [String: Int]
    private var requested: [String] = []

    init(payloads: [String: Data], failures: [String: Int] = [:]) {
        self.payloads = payloads
        self.failures = failures
    }

    func download(
        _ artifact: TranscriptionArtifact,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        requested.append(artifact.id)
        if let remaining = failures[artifact.id], remaining > 0 {
            failures[artifact.id] = remaining - 1
            throw URLError(.networkConnectionLost)
        }
        guard let payload = payloads[artifact.id] else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        progress(0, artifact.byteCount)
        try payload.write(to: destination)
        progress(Int64(payload.count), artifact.byteCount)
    }

    func requestCount() -> Int {
        requested.count
    }

    func requestedIDs() -> [String] {
        requested
    }
}

private struct FakeTranscriptionExtractor: TranscriptionArchiveExtracting {
    func extract(archive: URL, to directory: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if archive.lastPathComponent.contains("parakeet") {
            let root = directory.appendingPathComponent("parakeet-root", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try writeExecutable("#!/bin/sh\nexit 0\n", at: root.appendingPathComponent("parakeet-cli"))
            try Data("dylib".utf8).write(to: root.appendingPathComponent("libparakeet.dylib"))
            try Data("MIT".utf8).write(to: root.appendingPathComponent("LICENSE"))
        } else if archive.lastPathComponent.contains("ffmpeg") {
            try writeExecutable("#!/bin/sh\nexit 0\n", at: directory.appendingPathComponent("ffmpeg"))
            try Data("LGPL".utf8).write(to: directory.appendingPathComponent("COPYING.LGPLv2.1"))
        } else {
            throw TranscriptionProvisioningError.extractionFailed("unexpected archive")
        }
    }

    private func writeExecutable(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

private actor FakeTranscriptionValidator: TranscriptionValidating {
    private var error: Error?
    private var validated: [TranscriptionInstallation] = []

    func setError(_ error: Error?) {
        self.error = error
    }

    func validate(installation: TranscriptionInstallation) async throws {
        validated.append(installation)
        if let storedError = error {
            throw storedError
        }
    }

    func validationCount() -> Int {
        validated.count
    }
}

private final class SleepingTranscriptionDownloader: TranscriptionDownloading, @unchecked Sendable {
    func download(
        _ artifact: TranscriptionArtifact,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }
}

final class TranscriptionProvisionerTests: XCTestCase {
    private func temporaryPaths() throws -> (RelayPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (RelayPaths(root: root), root)
    }

    private func testArtifacts(
        engineData: Data = Data("engine-archive".utf8),
        modelData: Data = Data("model-data".utf8),
        decoderData: Data = Data("decoder-archive".utf8),
        modelHash: String? = nil
    ) -> (TranscriptionArtifacts, [String: Data]) {
        let engine = TranscriptionArtifact(
            kind: .engineArchive,
            id: "engine",
            url: URL(string: "https://example.test/parakeet-engine.tar.gz")!,
            sha256: sha256(engineData),
            byteCount: Int64(engineData.count),
            fileName: "parakeet-engine.tar.gz"
        )
        let model = TranscriptionArtifact(
            kind: .model,
            id: "model",
            url: URL(string: "https://example.test/model.gguf")!,
            sha256: modelHash ?? sha256(modelData),
            byteCount: Int64(modelData.count),
            fileName: "model.gguf"
        )
        let decoder = TranscriptionArtifact(
            kind: .decoderArchive,
            id: "decoder",
            url: URL(string: "https://example.test/ffmpeg.tar.gz")!,
            sha256: sha256(decoderData),
            byteCount: Int64(decoderData.count),
            fileName: "ffmpeg.tar.gz"
        )
        let artifacts = TranscriptionArtifacts(
            architecture: "arm64",
            engine: engine,
            model: model,
            decoder: decoder
        )
        return (
            artifacts,
            [
                engine.id: engineData,
                model.id: modelData,
                decoder.id: decoderData,
            ]
        )
    }

    func testCurrentArtifactsArePinnedPerArchitecture() throws {
        let arm = try TranscriptionArtifacts.current(architecture: "arm64")
        XCTAssertTrue(arm.engine.url.absoluteString.contains("metal-arm64"))
        XCTAssertEqual(
            arm.engine.sha256,
            "bc97b5e6253e928d1127f48f08242324317495ef8708e31db1e09b9537d1bb74"
        )
        XCTAssertEqual(arm.model.byteCount, 177_796_224)
        XCTAssertEqual(
            arm.model.sha256,
            "614feee3a990cf0e672b0314f4da0c80ae8da9094507f5ccb7c42e43b5fc5a12"
        )
        XCTAssertEqual(
            arm.decoder.sha256,
            "c725431e0b073bad12619d53c6d759b399ee84450790a8d681ecbb4066bf1194"
        )

        let intel = try TranscriptionArtifacts.current(architecture: "x86_64")
        XCTAssertTrue(intel.engine.url.absoluteString.contains("cpu-x64"))
        XCTAssertEqual(
            intel.engine.sha256,
            "82392069ea091c896dcf86fb5d86f20d107c71f6bad4b9e79a114523d98fb643"
        )

        XCTAssertThrowsError(try TranscriptionArtifacts.current(architecture: "ppc"))
    }

    func testProvisionDownloadsVerifiesAndInstalls() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (artifacts, payloads) = testArtifacts()
        let downloader = FakeTranscriptionDownloader(payloads: payloads)
        let validator = FakeTranscriptionValidator()
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: downloader,
            extractor: FakeTranscriptionExtractor(),
            validator: validator
        )

        let installation = try await provisioner.provision { _ in }

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.parakeetBinary.path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.ffmpeg.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installation.model.path))
        let modelAttributes = try FileManager.default.attributesOfItem(
            atPath: installation.model.path
        )
        let modelSize = modelAttributes[.size] as? NSNumber
        XCTAssertEqual(modelSize?.intValue ?? -1, payloads["model"]!.count)
        let engineDirectory = installation.parakeetBinary.deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: engineDirectory.appendingPathComponent("libparakeet.dylib").path
            ),
            "engine dylibs must be preserved"
        )
        let licenses = paths.transcriptionDirectory
            .appendingPathComponent("current/licenses", isDirectory: true)
        for name in [
            "NOTICE.txt",
            "LICENSE-MIT-parakeet.cpp.txt",
            "LICENSE-LGPL-2.1.txt",
            "LICENSE-CC-BY-4.0.txt",
        ] {
            let url = licenses.appendingPathComponent(name, isDirectory: false)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertGreaterThan(text.utf8.count, 200, "\(name) should contain license text")
        }
        let lgpl = try String(
            contentsOf: licenses.appendingPathComponent("LICENSE-LGPL-2.1.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(lgpl.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(lgpl.contains("Version 2.1"))
        let ccBy = try String(
            contentsOf: licenses.appendingPathComponent("LICENSE-CC-BY-4.0.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(ccBy.contains("Creative Commons Attribution 4.0 International"))
        let mit = try String(
            contentsOf: licenses.appendingPathComponent("LICENSE-MIT-parakeet.cpp.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(mit.contains("the parakeet.cpp authors"))
        let downloadCount = await downloader.requestCount()
        let validationCount = await validator.validationCount()
        XCTAssertEqual(downloadCount, 3)
        XCTAssertEqual(validationCount, 1)

        let state = await provisioner.initialState()
        guard case .ready(let loaded) = state else {
            return XCTFail("expected ready, got \(state)")
        }
        XCTAssertEqual(loaded.parakeetBinary.standardizedFileURL, installation.parakeetBinary.standardizedFileURL)
        XCTAssertEqual(loaded.model.standardizedFileURL, installation.model.standardizedFileURL)
    }

    func testProvisionDoesNotDownloadAgainWhenInstallationIsReady() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (artifacts, payloads) = testArtifacts()
        let downloader = FakeTranscriptionDownloader(payloads: payloads)
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: downloader,
            extractor: FakeTranscriptionExtractor(),
            validator: FakeTranscriptionValidator()
        )

        _ = try await provisioner.provision { _ in }
        _ = try await provisioner.provision { _ in }

        let count = await downloader.requestCount()
        XCTAssertEqual(count, 3)
    }

    func testCustomTranscriberSkipsProvisioning() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        try Data("HIGHLITE_RELAY_TRANSCRIBER_COMMAND=python3 asr.py\n".utf8)
            .write(to: paths.envFile)
        let (artifacts, payloads) = testArtifacts()
        let downloader = FakeTranscriptionDownloader(payloads: payloads)
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: downloader,
            extractor: FakeTranscriptionExtractor(),
            validator: FakeTranscriptionValidator()
        )

        let state = await provisioner.initialState()
        guard case .custom = state else {
            return XCTFail("expected custom, got \(state)")
        }
        do {
            _ = try await provisioner.provision { _ in }
            XCTFail("provisioning should not run for a custom transcriber")
        } catch let error as TranscriptionProvisioningError {
            guard case .customConfiguration = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let count = await downloader.requestCount()
        XCTAssertEqual(count, 0)
    }

    func testCustomParakeetPathsSkipProvisioning() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let environment = """
        HIGHLITE_RELAY_PARAKEET_BIN=/custom/parakeet-cli
        HIGHLITE_RELAY_PARAKEET_MODEL=/custom/model.gguf
        HIGHLITE_RELAY_FFMPEG=/custom/ffmpeg
        """
        try Data(environment.utf8).write(to: paths.envFile)
        let (artifacts, payloads) = testArtifacts()
        let downloader = FakeTranscriptionDownloader(payloads: payloads)
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: downloader,
            extractor: FakeTranscriptionExtractor(),
            validator: FakeTranscriptionValidator()
        )

        let state = await provisioner.initialState()
        guard case .custom = state else {
            return XCTFail("expected custom, got \(state)")
        }
        do {
            _ = try await provisioner.provision { _ in }
            XCTFail("provisioning should not run for custom Parakeet paths")
        } catch let error as TranscriptionProvisioningError {
            guard case .customConfiguration = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let count = await downloader.requestCount()
        XCTAssertEqual(count, 0)
    }

    func testChecksumMismatchLeavesNoCurrentInstallation() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (artifacts, payloads) = testArtifacts(modelHash: String(repeating: "0", count: 64))
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: FakeTranscriptionDownloader(payloads: payloads),
            extractor: FakeTranscriptionExtractor(),
            validator: FakeTranscriptionValidator()
        )

        do {
            _ = try await provisioner.provision { _ in }
            XCTFail("expected checksum failure")
        } catch let error as TranscriptionProvisioningError {
            guard case .checksumMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.transcriptionDirectory.appendingPathComponent("current").path
            )
        )
    }

    func testTransientDownloadFailuresAreRetried() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (artifacts, payloads) = testArtifacts()
        let downloader = FakeTranscriptionDownloader(
            payloads: payloads,
            failures: ["model": 2]
        )
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: downloader,
            extractor: FakeTranscriptionExtractor(),
            validator: FakeTranscriptionValidator()
        )

        _ = try await provisioner.provision { _ in }
        let requested = await downloader.requestedIDs()
        XCTAssertEqual(requested.filter { $0 == "model" }.count, 3)
    }

    func testFailedReplacementKeepsThePreviousInstallationActive() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (artifacts, payloads) = testArtifacts()
        let validator = FakeTranscriptionValidator()
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: FakeTranscriptionDownloader(payloads: payloads),
            extractor: FakeTranscriptionExtractor(),
            validator: validator
        )
        _ = try await provisioner.provision { _ in }

        let current = paths.transcriptionDirectory.appendingPathComponent("current")
        let previousTarget = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)

        let (newArtifacts, newPayloads) = testArtifacts(
            engineData: Data("engine-archive-2".utf8),
            decoderData: Data("decoder-archive-2".utf8)
        )
        await validator.setError(TranscriptionProvisioningError.validationFailed("bad install"))
        let replacement = TranscriptionProvisioner(
            paths: paths,
            artifacts: newArtifacts,
            downloader: FakeTranscriptionDownloader(payloads: newPayloads),
            extractor: FakeTranscriptionExtractor(),
            validator: validator
        )
        do {
            _ = try await replacement.provision { _ in }
            XCTFail("expected validation failure")
        } catch let error as TranscriptionProvisioningError {
            guard case .validationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let currentTarget = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        XCTAssertEqual(currentTarget, previousTarget)
    }

    func testCancellationRemovesStaging() async throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let (artifacts, _) = testArtifacts()
        let provisioner = TranscriptionProvisioner(
            paths: paths,
            artifacts: artifacts,
            downloader: SleepingTranscriptionDownloader(),
            extractor: FakeTranscriptionExtractor(),
            validator: FakeTranscriptionValidator()
        )

        let task = Task {
            try await provisioner.provision { _ in }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: paths.transcriptionDirectory.path
        )
        XCTAssertFalse(entries.contains { $0.hasPrefix(".staging-") })
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
