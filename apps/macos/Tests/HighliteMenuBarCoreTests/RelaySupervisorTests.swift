import Foundation
import XCTest
@testable import HighliteMenuBarCore

private final class SupervisorTokenStore: RelayTokenStoring {
    var values: [String: String] = [
        RelayTokenAccount.read: "read-token",
        RelayTokenAccount.ingest: "ingest-token",
    ]

    func string(for account: String) throws -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) throws { values.removeValue(forKey: account) }
}

private actor ScriptedProbe: RelayProbing {
    enum Step {
        case health(RelayHealth, TimeInterval)
        case failure(RelayAPIError, TimeInterval)
    }

    private var steps: [Step]
    private let sessions: [SessionMetadata]

    init(steps: [Step], sessions: [SessionMetadata] = []) {
        self.steps = steps
        self.sessions = sessions
    }

    func health(timeout: TimeInterval) async throws -> RelayHealth {
        guard !steps.isEmpty else {
            throw RelayAPIError.network("Unexpected probe call")
        }
        switch steps.removeFirst() {
        case .health(let health, let delay):
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            return health
        case .failure(let error, let delay):
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            throw error
        }
    }

    func listSessions(timeout: TimeInterval) async throws -> [SessionMetadata] {
        sessions
    }
}

final class RelaySupervisorTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(at url: URL) throws {
        let script = "#!/bin/sh\nexec sleep 30\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func settings(binaryPath: String = "") -> AppSettings {
        AppSettings(port: 18_787, allowedOrigins: "", relayBinaryPath: binaryPath)
    }

    private func health() -> RelayHealth {
        RelayHealth(status: "ok", compiler: "highlite-relay", version: "1.0.0")
    }

    func testDelayedAttachProbeThenStopCancelsAndLeavesStoppedState() async throws {
        try await delayedAttachProbeScenario()
    }

    @MainActor
    private func delayedAttachProbeScenario() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RelayPaths(root: root)
        let probe = ScriptedProbe(steps: [
            .health(health(), 0.35),
            .health(health(), 0),
        ])
        let supervisor = RelaySupervisor(
            paths: paths,
            tokenStore: SupervisorTokenStore(),
            probeFactory: { _, _ in probe },
            locateBinary: { _ in nil }
        )
        let settings = settings()

        let task = Task { try await supervisor.start(settings: settings) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await supervisor.stop()
        let result = await task.result

        guard case .failure(let error) = result else {
            return XCTFail("Expected cancelled startup")
        }
        XCTAssertEqual(error as? RelayStartError, .cancelled)
        XCTAssertEqual(supervisor.snapshot.phase, .stopped)
        XCTAssertNil(supervisor.active)
        XCTAssertFalse(supervisor.ownsRunningProcess)

        // A stale cancelled startup must not overwrite the next attempt.
        let connection = try await supervisor.start(settings: settings)
        XCTAssertFalse(connection.owned)
        XCTAssertEqual(supervisor.snapshot.phase, .running)
        await supervisor.stop()
        XCTAssertEqual(supervisor.snapshot.phase, .stopped)
    }

    func testConflictFailureIsRetryableAndSetsFailedState() async throws {
        try await conflictRetryScenario()
    }

    @MainActor
    private func conflictRetryScenario() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-relay")
        try makeExecutable(at: script)
        let paths = RelayPaths(root: root.appendingPathComponent("Highlite"))
        let probe = ScriptedProbe(steps: [
            .failure(.http(status: 409, message: "conflict"), 0),
            .failure(.network("free port"), 0),
            .health(health(), 0),
        ])
        let supervisor = RelaySupervisor(
            paths: paths,
            tokenStore: SupervisorTokenStore(),
            probeFactory: { _, _ in probe },
            locateBinary: { _ in script }
        )
        let settings = settings(binaryPath: script.path)

        do {
            _ = try await supervisor.start(settings: settings)
            XCTFail("Expected a port conflict")
        } catch let error as RelayStartError {
            guard case .portConflict = error else {
                return XCTFail("Expected portConflict, got \(error)")
            }
        }
        XCTAssertEqual(supervisor.snapshot.phase, .failed)

        let connection = try await supervisor.start(settings: settings)
        XCTAssertTrue(connection.owned)
        XCTAssertEqual(supervisor.snapshot.phase, .running)
        XCTAssertTrue(supervisor.ownsRunningProcess)
        await supervisor.stop()
        XCTAssertEqual(supervisor.snapshot.phase, .stopped)
        XCTAssertFalse(supervisor.ownsRunningProcess)
    }

    func testStopDuringReadinessKillsOwnedChildAndPreventsRunningSnapshot() async throws {
        try await stopDuringReadinessScenario()
    }

    @MainActor
    private func stopDuringReadinessScenario() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-relay")
        try makeExecutable(at: script)
        let paths = RelayPaths(root: root.appendingPathComponent("Highlite"))
        let probe = ScriptedProbe(steps: [
            .failure(.network("free port"), 0),
            .health(health(), 0.5),
        ])
        let supervisor = RelaySupervisor(
            paths: paths,
            tokenStore: SupervisorTokenStore(),
            probeFactory: { _, _ in probe },
            locateBinary: { _ in script }
        )
        let settings = settings(binaryPath: script.path)

        let task = Task { try await supervisor.start(settings: settings) }
        var spawned = false
        for _ in 0..<30 {
            if supervisor.ownsRunningProcess {
                spawned = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(spawned, "Expected the fake relay child to start")
        await supervisor.stop()
        let result = await task.result

        guard case .failure(let error) = result else {
            return XCTFail("Expected cancelled startup")
        }
        XCTAssertEqual(error as? RelayStartError, .cancelled)
        XCTAssertEqual(supervisor.snapshot.phase, .stopped)
        XCTAssertFalse(supervisor.ownsRunningProcess)
        XCTAssertNil(supervisor.active)
    }
}
