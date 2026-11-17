import Foundation
import XCTest
@testable import HighliteMenuBarCore

private final class FakeTokenStore: RelayTokenStoring {
    var values: [String: String] = [:]
    var readError: Error?
    var writeError: Error?

    func string(for account: String) throws -> String? {
        if let readError { throw readError }
        return values[account]
    }

    func set(_ value: String, for account: String) throws {
        if let writeError { throw writeError }
        values[account] = value
    }

    func remove(_ account: String) throws {
        values.removeValue(forKey: account)
    }
}

final class RelayEnvironmentTests: XCTestCase {
    private func temporaryPaths() throws -> (RelayPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (RelayPaths(root: root.appendingPathComponent("Highlite")), root)
    }

    func testPrepareGeneratesTokensAndPrivatePermissions() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FakeTokenStore()

        let tokens = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: ["http://localhost:5173"],
            tokenStore: store
        )

        XCTAssertEqual(tokens.readToken.count, 64)
        XCTAssertEqual(tokens.ingestToken.count, 64)
        XCTAssertTrue(tokens.readToken.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(tokens.readToken, tokens.ingestToken)
        XCTAssertEqual(store.values[RelayTokenAccount.read], tokens.readToken)
        XCTAssertEqual(store.values[RelayTokenAccount.ingest], tokens.ingestToken)

        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertEqual(values[RelayEnvironment.readTokenKey], tokens.readToken)
        XCTAssertEqual(values[RelayEnvironment.ingestTokenKey], tokens.ingestToken)
        XCTAssertEqual(values[RelayEnvironment.originsKey], "http://localhost:5173")

        let envMode = try permissions(at: paths.envFile)
        let configMode = try permissions(at: paths.configDirectory)
        let dataMode = try permissions(at: paths.dataDirectory)
        let transcriptionMode = try permissions(at: paths.transcriptionDirectory)
        XCTAssertEqual(envMode, 0o600)
        XCTAssertEqual(configMode, 0o700)
        XCTAssertEqual(dataMode, 0o700)
        XCTAssertEqual(transcriptionMode, 0o700)
    }

    func testPreparePreservesExistingTokenAndUnrelatedSettings() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = """
        # manually managed
        HIGHLITE_RELAY_READ_TOKEN=existing-read-token
        HIGHLITE_RELAY_MAX_UPLOAD_MB=32
        CUSTOM_SETTING=keep-me
        """
        try Data(original.utf8).write(to: paths.envFile)
        let store = FakeTokenStore()
        store.values[RelayTokenAccount.ingest] = "old-ingest"

        let tokens = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: [],
            tokenStore: store
        )

        XCTAssertEqual(tokens.readToken, "existing-read-token")
        XCTAssertEqual(tokens.ingestToken, "old-ingest")
        let text = try String(contentsOf: paths.envFile, encoding: .utf8)
        XCTAssertTrue(text.contains("HIGHLITE_RELAY_READ_TOKEN=existing-read-token"))
        XCTAssertTrue(text.contains("HIGHLITE_RELAY_MAX_UPLOAD_MB=32"))
        XCTAssertTrue(text.contains("CUSTOM_SETTING=keep-me"))
        XCTAssertFalse(text.contains(RelayEnvironment.originsKey))
        XCTAssertEqual(store.values[RelayTokenAccount.read], "existing-read-token")
    }

    func testOriginsAreUpdatedWithoutDuplicatingKey() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FakeTokenStore()
        _ = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: ["https://old.example.com"],
            tokenStore: store
        )
        _ = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: ["https://new.example.com", "http://localhost:5173"],
            tokenStore: store
        )
        let text = try String(contentsOf: paths.envFile, encoding: .utf8)
        let occurrences = text.components(separatedBy: RelayEnvironment.originsKey).count - 1
        XCTAssertEqual(occurrences, 1)
        XCTAssertTrue(text.contains("https://new.example.com,http://localhost:5173"))
        XCTAssertFalse(text.contains("https://old.example.com"))
    }

    func testAllowedHostsAreMergedWithoutDroppingExistingHosts() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = "HIGHLITE_RELAY_ALLOWED_HOSTS=relay.example.com\n"
        try Data(original.utf8).write(to: paths.envFile)
        let store = FakeTokenStore()

        _ = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: [],
            allowedHosts: ["127.0.0.1:8787", "localhost:8787"],
            tokenStore: store
        )
        _ = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: [],
            allowedHosts: ["127.0.0.1:8787", "localhost:8787"],
            tokenStore: store
        )

        let values = try RelayEnvironment.readValues(paths: paths)
        let hosts = values[RelayEnvironment.hostsKey]?.split(separator: ",").map(String.init)
        XCTAssertEqual(hosts?.contains("relay.example.com"), true)
        XCTAssertEqual(hosts?.contains("127.0.0.1:8787"), true)
        XCTAssertEqual(hosts?.filter { $0 == "127.0.0.1:8787" }.count, 1)
    }

    func testTokensAreWrittenWhenKeychainHasValues() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FakeTokenStore()
        store.values[RelayTokenAccount.read] = "read-from-keychain"
        store.values[RelayTokenAccount.ingest] = "ingest-from-keychain"

        let tokens = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: [],
            tokenStore: store
        )
        XCTAssertEqual(tokens.readToken, "read-from-keychain")
        XCTAssertEqual(tokens.ingestToken, "ingest-from-keychain")
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertEqual(values[RelayEnvironment.readTokenKey], "read-from-keychain")
        XCTAssertEqual(values[RelayEnvironment.ingestTokenKey], "ingest-from-keychain")
    }

    func testParseValuesHandlesQuotesCommentsAndExport() {
        let values = RelayEnvironment.parseValues(
            """
            # comment
            export HIGHLITE_RELAY_BIND=127.0.0.1:9000
            HIGHLITE_RELAY_ALLOWED_ORIGINS="http://localhost:3000,https://app.example.com"
            PATH_WITH_SPACE='/tmp/a b'
            EMPTY=
            """
        )
        XCTAssertEqual(values["HIGHLITE_RELAY_BIND"], "127.0.0.1:9000")
        XCTAssertEqual(
            values["HIGHLITE_RELAY_ALLOWED_ORIGINS"],
            "http://localhost:3000,https://app.example.com"
        )
        XCTAssertEqual(values["PATH_WITH_SPACE"], "/tmp/a b")
        XCTAssertEqual(values["EMPTY"], "")
    }

    func testKeychainReadFailureStopsStartup() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FakeTokenStore()
        store.readError = RelayEnvironmentError.keychain("denied")

        XCTAssertThrowsError(
            try RelayEnvironment.prepare(paths: paths, allowedOrigins: [], tokenStore: store)
        ) { error in
            XCTAssertTrue(error is RelayEnvironmentError)
        }
    }


    func testInvalidExistingTokensAreReplacedWhileValidTokensArePreserved() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let oversized = String(repeating: "a", count: 5_000)
        let original = """
        HIGHLITE_RELAY_READ_TOKEN="bad\tread"
        HIGHLITE_RELAY_INGEST_TOKEN=\(oversized)
        """
        try Data(original.utf8).write(to: paths.envFile)
        let store = FakeTokenStore()
        store.values[RelayTokenAccount.read] = "valid-read"
        store.values[RelayTokenAccount.ingest] = "valid-ingest"

        let tokens = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: [],
            tokenStore: store
        )

        XCTAssertEqual(tokens.readToken, "valid-read")
        XCTAssertEqual(tokens.ingestToken, "valid-ingest")
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertEqual(values[RelayEnvironment.readTokenKey], "valid-read")
        XCTAssertEqual(values[RelayEnvironment.ingestTokenKey], "valid-ingest")
        XCTAssertEqual(store.values[RelayTokenAccount.read], "valid-read")
        XCTAssertEqual(store.values[RelayTokenAccount.ingest], "valid-ingest")
    }

    func testMixedValidAndInvalidTokenListKeepsOnlyValidTokens() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = """
        HIGHLITE_RELAY_READ_TOKEN="bad\tread",good-token
        HIGHLITE_RELAY_INGEST_TOKEN=good-ingest
        """
        try Data(original.utf8).write(to: paths.envFile)
        let store = FakeTokenStore()

        let tokens = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: [],
            tokenStore: store
        )
        XCTAssertEqual(tokens.readToken, "good-token")
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertEqual(values[RelayEnvironment.readTokenKey], "good-token")
        XCTAssertEqual(values[RelayEnvironment.ingestTokenKey], "good-ingest")
    }

    func testEnvFileSymlinkIsRejectedAndTempFileCleanedUp() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("outside.env")
        let sentinel = "DO NOT OVERWRITE\n"
        try Data(sentinel.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: paths.envFile,
            withDestinationURL: target
        )
        let store = FakeTokenStore()

        XCTAssertThrowsError(
            try RelayEnvironment.prepare(paths: paths, allowedOrigins: [], tokenStore: store)
        ) { error in
            guard let relayError = error as? RelayEnvironmentError,
                  case .cannotWrite = relayError
            else {
                return XCTFail("Expected cannotWrite, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), sentinel)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: paths.supportDirectory.path
        )
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".tmp") })
    }

    func testSuccessfulWriteLeavesNoTemporaryFile() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try RelayEnvironment.prepare(
            paths: paths,
            allowedOrigins: ["http://localhost:5173"],
            tokenStore: FakeTokenStore()
        )
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: paths.supportDirectory.path
        )
        XCTAssertTrue(contents.contains("relay.env"))
        XCTAssertFalse(contents.contains { $0.hasPrefix(".relay.env.") && $0.hasSuffix(".tmp") })
    }

    func testTranscriptionConfigurationWritesKeysAndPreservesUnrelatedSettings() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = """
        # manually managed
        HIGHLITE_RELAY_MAX_UPLOAD_MB=32
        CUSTOM_SETTING=keep-me
        """
        try Data(original.utf8).write(to: paths.envFile)

        let bin = paths.transcriptionDirectory
            .appendingPathComponent("current/engine/Highlite Tools/parakeet-cli").path
        let model = paths.transcriptionDirectory
            .appendingPathComponent("current/model/Parakeet Models/model.gguf").path
        let ffmpeg = paths.transcriptionDirectory
            .appendingPathComponent("current/decoder/FFmpeg Tools/ffmpeg").path
        let outcome = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: bin,
            parakeetModel: model,
            ffmpeg: ffmpeg
        )

        XCTAssertFalse(outcome.isCustom)
        XCTAssertTrue(outcome.wrote)
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertEqual(values[RelayEnvironment.parakeetBinKey], bin)
        XCTAssertEqual(values[RelayEnvironment.parakeetModelKey], model)
        XCTAssertEqual(values[RelayEnvironment.ffmpegKey], ffmpeg)
        let text = try String(contentsOf: paths.envFile, encoding: .utf8)
        XCTAssertTrue(text.contains("HIGHLITE_RELAY_MAX_UPLOAD_MB=32"))
        XCTAssertTrue(text.contains("CUSTOM_SETTING=keep-me"))
        let envMode = try permissions(at: paths.envFile)
        XCTAssertEqual(envMode, 0o600)
    }

    func testTranscriptionConfigurationPreservesCustomTranscriberCommand() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = """
        HIGHLITE_RELAY_TRANSCRIBER_COMMAND=python3 asr.py
        """
        try Data(original.utf8).write(to: paths.envFile)

        let outcome = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: "/app/parakeet-cli",
            parakeetModel: "/app/model.gguf",
            ffmpeg: "/app/ffmpeg"
        )

        XCTAssertTrue(outcome.isCustom)
        XCTAssertFalse(outcome.wrote)
        XCTAssertEqual(outcome.preservedKeys, [RelayEnvironment.transcriberCommandKey])
        let text = try String(contentsOf: paths.envFile, encoding: .utf8)
        XCTAssertEqual(text, original)
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertNil(values[RelayEnvironment.parakeetBinKey])
        XCTAssertNil(values[RelayEnvironment.parakeetModelKey])
        XCTAssertNil(values[RelayEnvironment.ffmpegKey])
    }

    func testTranscriptionConfigurationPreservesCustomASRCommand() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = """
        HIGHLITE_ASR_COMMAND=whisper-cli -m model.bin
        """
        try Data(original.utf8).write(to: paths.envFile)

        let outcome = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: "/app/parakeet-cli",
            parakeetModel: "/app/model.gguf",
            ffmpeg: "/app/ffmpeg"
        )

        XCTAssertTrue(outcome.isCustom)
        XCTAssertFalse(outcome.wrote)
        XCTAssertEqual(outcome.preservedKeys, [RelayEnvironment.asrCommandKey])
        let text = try String(contentsOf: paths.envFile, encoding: .utf8)
        XCTAssertEqual(text, original)
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertNil(values[RelayEnvironment.parakeetBinKey])
        XCTAssertNil(values[RelayEnvironment.parakeetModelKey])
    }

    func testTranscriptionConfigurationPreservesCustomParakeetPaths() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = """
        HIGHLITE_RELAY_PARAKEET_BIN=/custom/parakeet-cli
        HIGHLITE_RELAY_PARAKEET_MODEL=/custom/model.gguf
        """
        try Data(original.utf8).write(to: paths.envFile)

        let outcome = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: "/app/parakeet-cli",
            parakeetModel: "/app/model.gguf",
            ffmpeg: "/app/ffmpeg"
        )

        XCTAssertTrue(outcome.isCustom)
        XCTAssertFalse(outcome.wrote)
        XCTAssertEqual(
            Set(outcome.preservedKeys),
            Set([RelayEnvironment.parakeetBinKey, RelayEnvironment.parakeetModelKey])
        )
        let text = try String(contentsOf: paths.envFile, encoding: .utf8)
        XCTAssertEqual(text, original)
    }

    func testTranscriptionConfigurationReplacesOnlyAppOwnedPaths() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let oldBin = paths.transcriptionDirectory.appendingPathComponent("old/parakeet-cli").path
        let oldModel = paths.transcriptionDirectory.appendingPathComponent("old/model.gguf").path
        let oldFFmpeg = paths.transcriptionDirectory.appendingPathComponent("old/ffmpeg").path
        let original = """
        HIGHLITE_RELAY_PARAKEET_BIN=\(oldBin)
        HIGHLITE_RELAY_PARAKEET_MODEL=\(oldModel)
        HIGHLITE_RELAY_FFMPEG=\(oldFFmpeg)
        """
        try Data(original.utf8).write(to: paths.envFile)

        let newBin = paths.transcriptionDirectory.appendingPathComponent("current/engine/parakeet-cli").path
        let newModel = paths.transcriptionDirectory.appendingPathComponent("current/model/model.gguf").path
        let newFFmpeg = paths.transcriptionDirectory.appendingPathComponent("current/decoder/ffmpeg").path
        let outcome = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: newBin,
            parakeetModel: newModel,
            ffmpeg: newFFmpeg
        )

        XCTAssertFalse(outcome.isCustom)
        XCTAssertTrue(outcome.wrote)
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertEqual(values[RelayEnvironment.parakeetBinKey], newBin)
        XCTAssertEqual(values[RelayEnvironment.parakeetModelKey], newModel)
        XCTAssertEqual(values[RelayEnvironment.ffmpegKey], newFFmpeg)
    }

    func testTranscriptionConfigurationPreservesCustomFFmpegOnly() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        let original = """
        HIGHLITE_RELAY_FFMPEG=/custom/ffmpeg
        """
        try Data(original.utf8).write(to: paths.envFile)

        let bin = paths.transcriptionDirectory.appendingPathComponent("current/engine/parakeet-cli").path
        let model = paths.transcriptionDirectory.appendingPathComponent("current/model/model.gguf").path
        let outcome = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: bin,
            parakeetModel: model,
            ffmpeg: paths.transcriptionDirectory.appendingPathComponent("current/decoder/ffmpeg").path
        )

        XCTAssertFalse(outcome.isCustom)
        XCTAssertTrue(outcome.wrote)
        XCTAssertEqual(outcome.preservedKeys, [RelayEnvironment.ffmpegKey])
        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertEqual(values[RelayEnvironment.parakeetBinKey], bin)
        XCTAssertEqual(values[RelayEnvironment.parakeetModelKey], model)
        XCTAssertEqual(values[RelayEnvironment.ffmpegKey], "/custom/ffmpeg")
    }

    func testTranscriptionConfigurationRemovesEmptyCommandKeys() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true
        )
        try Data("HIGHLITE_RELAY_TRANSCRIBER_COMMAND=\n".utf8).write(to: paths.envFile)
        let bin = paths.transcriptionDirectory.appendingPathComponent("current/engine/parakeet-cli").path
        let model = paths.transcriptionDirectory.appendingPathComponent("current/model/model.gguf").path
        let ffmpeg = paths.transcriptionDirectory.appendingPathComponent("current/decoder/ffmpeg").path

        _ = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: bin,
            parakeetModel: model,
            ffmpeg: ffmpeg
        )

        let values = try RelayEnvironment.readValues(paths: paths)
        XCTAssertNil(values[RelayEnvironment.transcriberCommandKey])
        XCTAssertEqual(values[RelayEnvironment.parakeetBinKey], bin)
    }

    func testTranscriptionConfigurationIsIdempotent() throws {
        let (paths, root) = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = paths.transcriptionDirectory.appendingPathComponent("current/engine/parakeet-cli").path
        let model = paths.transcriptionDirectory.appendingPathComponent("current/model/model.gguf").path
        let ffmpeg = paths.transcriptionDirectory.appendingPathComponent("current/decoder/ffmpeg").path
        _ = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: bin,
            parakeetModel: model,
            ffmpeg: ffmpeg
        )
        let second = try RelayEnvironment.configureTranscription(
            paths: paths,
            parakeetBin: bin,
            parakeetModel: model,
            ffmpeg: ffmpeg
        )
        XCTAssertFalse(second.wrote)
        XCTAssertFalse(second.isCustom)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let number = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return number.intValue & 0o777
    }
}
