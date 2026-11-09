import Combine
import Darwin
import Foundation

public enum RelayPhase: String, Hashable, Sendable {
    case stopped
    case checking
    case starting
    case running
    case stopping
    case failed
}

public struct RelaySnapshot: Equatable, Sendable {
    public var phase: RelayPhase
    public var owned: Bool
    public var pid: Int32?
    public var baseURL: URL
    public var detail: String
    public var relayVersion: String?

    public var isRunning: Bool { phase == .running }

    public static func stopped(baseURL: URL = URL(string: "http://127.0.0.1:8787")!) -> RelaySnapshot {
        RelaySnapshot(
            phase: .stopped,
            owned: false,
            pid: nil,
            baseURL: baseURL,
            detail: "Relay is stopped.",
            relayVersion: nil
        )
    }
}

public struct RelayConnection: Equatable, Sendable {
    public var baseURL: URL
    public var tokens: RelayTokens
    public var owned: Bool

    public init(baseURL: URL, tokens: RelayTokens, owned: Bool) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.owned = owned
    }
}

/// The two read-only relay probes needed to attach to or verify a relay.
public protocol RelayProbing: Sendable {
    func health(timeout: TimeInterval) async throws -> RelayHealth
    func listSessions(timeout: TimeInterval) async throws -> [SessionMetadata]
}

public struct RelayProbeClient: RelayProbing {
    private let client: RelayClient

    public init(client: RelayClient) {
        self.client = client
    }

    public func health(timeout: TimeInterval) async throws -> RelayHealth {
        try await client.health(timeout: timeout)
    }

    public func listSessions(timeout: TimeInterval) async throws -> [SessionMetadata] {
        try await client.listSessions(timeout: timeout)
    }
}

public typealias RelayProbeFactory = @Sendable (URL, String) async throws -> any RelayProbing
public typealias RelayBinaryResolver = @Sendable (String?) -> URL?

public enum RelayStartError: LocalizedError, Equatable {
    case busy
    case cancelled
    case relayNotFound
    case portConflict(String)
    case authenticationConflict
    case launchFailed(String)
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "The relay is already changing state. Try again in a moment."
        case .cancelled:
            return "Relay startup was cancelled."
        case .relayNotFound:
            return "The highlite-relay binary was not found. Set it in Settings or bundle it in the app."
        case .portConflict(let detail):
            return detail
        case .authenticationConflict:
            return "A service is already using this port, but the stored relay read token does not authenticate. Stop the other relay or choose a different local port."
        case .launchFailed(let detail):
            return detail
        case .notReady(let detail):
            return detail
        }
    }
}

public enum RelayBinaryLocator {
    public static func locate(
        configuredPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        let fileManager = FileManager.default

        func resolve(_ raw: String) -> URL? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if value.contains("/") {
                let url = URL(fileURLWithPath: value, isDirectory: false)
                return fileManager.isExecutableFile(atPath: url.path) ? url : nil
            }
            for directory in OpenCodeLocator.augmentedPATH(environment: environment).split(separator: ":") {
                let url = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(value, isDirectory: false)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
            return nil
        }

        if let configuredPath,
           !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resolve(configuredPath)
        }
        if let environmentPath = environment["HIGHLITE_RELAY_BIN"],
           !environmentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resolve(environmentPath)
        }

        let bundled = [
            bundleURL.appendingPathComponent("Contents/Resources/highlite-relay", isDirectory: false),
            bundleURL.appendingPathComponent("Resources/highlite-relay", isDirectory: false),
            bundleURL.appendingPathComponent("highlite-relay", isDirectory: false),
        ]
        for candidate in bundled where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        var directory = currentDirectory
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("target/release/highlite-relay", isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            let packageRelative = directory.appendingPathComponent(
                "apps/macos/target/release/highlite-relay",
                isDirectory: false
            )
            if fileManager.isExecutableFile(atPath: packageRelative.path) {
                return packageRelative
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}

@MainActor
public final class RelaySupervisor: ObservableObject {
    @Published public private(set) var snapshot: RelaySnapshot
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var tokens: RelayTokens?

    private let paths: RelayPaths
    private let tokenStore: RelayTokenStoring
    private let probeFactory: RelayProbeFactory
    private let locateBinary: RelayBinaryResolver
    private var process: Process?
    private var ownedPID: Int32?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var activeConnection: RelayConnection?
    private var startupGeneration: UInt64 = 0
    private var startupInProgress = false
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        paths: RelayPaths = .standard(),
        tokenStore: RelayTokenStoring = KeychainStore(),
        probeFactory: @escaping RelayProbeFactory = RelaySupervisor.defaultProbe,
        locateBinary: @escaping RelayBinaryResolver = { RelayBinaryLocator.locate(configuredPath: $0) }
    ) {
        self.paths = paths
        self.tokenStore = tokenStore
        self.probeFactory = probeFactory
        self.locateBinary = locateBinary
        self.snapshot = .stopped()
    }

    public nonisolated static func defaultProbe(
        baseURL: URL,
        readToken: String
    ) async throws -> any RelayProbing {
        let client = RelayClient()
        try await client.configure(baseURL: baseURL, readToken: readToken)
        return RelayProbeClient(client: client)
    }

    public var active: RelayConnection? { activeConnection }

    /// Internal test seam: true only while this supervisor owns a live child.
    var ownsRunningProcess: Bool {
        process?.isRunning == true
    }

    public func start(settings: AppSettings) async throws -> RelayConnection {
        if let activeConnection, snapshot.phase == .running {
            return activeConnection
        }
        guard !startupInProgress else {
            throw RelayStartError.busy
        }
        guard snapshot.phase != .checking,
              snapshot.phase != .starting,
              snapshot.phase != .stopping
        else {
            throw RelayStartError.busy
        }
        if process != nil {
            await stop()
        }

        startupInProgress = true
        startupGeneration &+= 1
        let generation = startupGeneration
        defer { finishStartup() }

        do {
            return try await startInternal(settings: settings, generation: generation)
        } catch {
            await stopOwnedChildIfSafe()
            if generation == startupGeneration {
                snapshot = RelaySnapshot(
                    phase: .failed,
                    owned: false,
                    pid: nil,
                    baseURL: settings.baseURL,
                    detail: error.localizedDescription,
                    relayVersion: nil
                )
            }
            throw error
        }
    }

    private func startInternal(
        settings: AppSettings,
        generation: UInt64
    ) async throws -> RelayConnection {
        let validated: AppSettings
        do {
            validated = try settings.validated()
        } catch {
            snapshot = RelaySnapshot(
                phase: .failed,
                owned: false,
                pid: nil,
                baseURL: settings.baseURL,
                detail: error.localizedDescription,
                relayVersion: nil
            )
            throw error
        }

        let baseURL = validated.baseURL
        snapshot = RelaySnapshot(
            phase: .checking,
            owned: false,
            pid: nil,
            baseURL: baseURL,
            detail: "Checking whether a relay is already running...",
            relayVersion: nil
        )

        let relayTokens: RelayTokens
        do {
            relayTokens = try RelayEnvironment.prepare(
                paths: paths,
                allowedOrigins: validated.allowedOriginList,
                allowedHosts: [
                    "127.0.0.1:\(validated.port)",
                    "localhost:\(validated.port)",
                ],
                tokenStore: tokenStore
            )
        } catch {
            let detail = error.localizedDescription
            snapshot = RelaySnapshot(
                phase: .failed,
                owned: false,
                pid: nil,
                baseURL: baseURL,
                detail: detail,
                relayVersion: nil
            )
            throw error
        }
        tokens = relayTokens

        let probe: any RelayProbing
        do {
            probe = try await probeFactory(baseURL, relayTokens.readToken)
        } catch {
            throw error
        }
        try ensureStartupCurrent(generation)

        // Attach only when both health and authenticated reads succeed.
        do {
            let health = try await probe.health(timeout: 2)
            try ensureStartupCurrent(generation)
            guard health.isOK else {
                throw RelayStartError.portConflict(
                    "A service is using this port but is not a healthy Highlite relay. Choose another port or stop that service."
                )
            }
            do {
                _ = try await probe.listSessions(timeout: 5)
            } catch let error as RelayAPIError {
                if error.statusCode == 401 || error.statusCode == 403 {
                    throw RelayStartError.authenticationConflict
                }
                throw RelayStartError.portConflict(
                    "A relay is already running on this port, but it could not be authenticated. \(error.localizedDescription)"
                )
            }
            try ensureStartupCurrent(generation)
            let connection = RelayConnection(
                baseURL: baseURL,
                tokens: relayTokens,
                owned: false
            )
            activeConnection = connection
            snapshot = RelaySnapshot(
                phase: .running,
                owned: false,
                pid: nil,
                baseURL: baseURL,
                detail: "Attached to an existing relay. This app will never stop it.",
                relayVersion: health.version
            )
            appendLog("Attached to an existing relay at \(baseURL.absoluteString).")
            return connection
        } catch let error as RelayAPIError {
            switch error {
            case .network(_):
                // Nothing answered; launch our own relay below.
                break
            case .timeout:
                throw RelayStartError.portConflict(
                    "Something is using this port but did not answer the relay health check. Choose another port or stop that service."
                )
            default:
                throw RelayStartError.portConflict(
                    "Something is using this port but the relay health check failed. Choose another port or stop that service."
                )
            }
        } catch let error as RelayStartError {
            throw error
        } catch {
            throw RelayStartError.portConflict(
                "Something is using this port but it is not a healthy Highlite relay. Choose another port or stop that service."
            )
        }
        try ensureStartupCurrent(generation)

        guard let binary = locateBinary(validated.relayBinaryPath) else {
            snapshot = RelaySnapshot(
                phase: .failed,
                owned: false,
                pid: nil,
                baseURL: baseURL,
                detail: RelayStartError.relayNotFound.localizedDescription,
                relayVersion: nil
            )
            throw RelayStartError.relayNotFound
        }

        snapshot = RelaySnapshot(
            phase: .starting,
            owned: true,
            pid: nil,
            baseURL: baseURL,
            detail: "Starting bundled relay...",
            relayVersion: nil
        )

        let child = Process()
        child.executableURL = binary
        child.arguments = [
            "--env-file", paths.envFile.path,
            "--bind", "127.0.0.1:\(validated.port)",
            "--data-dir", paths.dataDirectory.path,
            "--config-dir", paths.configDirectory.path,
        ]
        child.environment = OpenCodeLocator.childEnvironment()
        child.currentDirectoryURL = paths.dataDirectory
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.handleTermination(finished)
            }
        }

        try ensureStartupCurrent(generation)
        do {
            try child.run()
        } catch {
            let detail = "The relay binary could not be launched: \(binary.path)."
            snapshot = RelaySnapshot(
                phase: .failed,
                owned: false,
                pid: nil,
                baseURL: baseURL,
                detail: detail,
                relayVersion: nil
            )
            throw RelayStartError.launchFailed(detail)
        }

        process = child
        ownedPID = child.processIdentifier
        outputPipe = stdoutPipe
        errorPipe = stderrPipe
        attachLogs(stdoutPipe)
        attachLogs(stderrPipe)
        try ensureStartupCurrent(generation)

        var readyHealth: RelayHealth?
        var lastFailure: String?
        readiness: for attempt in 0..<60 {
            try ensureStartupCurrent(generation)
            if !child.isRunning {
                lastFailure = "The relay exited before it became ready."
                break
            }
            do {
                let health = try await probe.health(timeout: 2)
                try ensureStartupCurrent(generation)
                if health.isOK {
                    do {
                        _ = try await probe.listSessions(timeout: 4)
                    } catch let error as RelayAPIError {
                        lastFailure = "The relay rejected its generated read token. \(error.localizedDescription)"
                        break readiness
                    }
                    try ensureStartupCurrent(generation)
                    readyHealth = health
                    break
                } else {
                    lastFailure = "The relay health check returned an unhealthy status."
                }
            } catch let error as RelayStartError {
                throw error
            } catch {
                lastFailure = error.localizedDescription
            }
            if attempt < 59 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                try ensureStartupCurrent(generation)
            }
        }

        guard let readyHealth else {
            throw RelayStartError.notReady(lastFailure ?? "The relay did not become ready in time.")
        }
        try ensureStartupCurrent(generation)

        let connection = RelayConnection(
            baseURL: baseURL,
            tokens: relayTokens,
            owned: true
        )
        activeConnection = connection
        snapshot = RelaySnapshot(
            phase: .running,
            owned: true,
            pid: child.processIdentifier,
            baseURL: baseURL,
            detail: "Relay is running at \(baseURL.absoluteString).",
            relayVersion: readyHealth.version
        )
        appendLog("Relay started (pid \(child.processIdentifier)), version \(readyHealth.version).")
        return connection
    }

    public func stop() async {
        startupGeneration &+= 1
        let hadStartup = startupInProgress
        if process != nil || hadStartup {
            snapshot = RelaySnapshot(
                phase: .stopping,
                owned: process != nil,
                pid: ownedPID,
                baseURL: snapshot.baseURL,
                detail: hadStartup && process == nil ? "Cancelling relay startup..." : "Stopping relay...",
                relayVersion: snapshot.relayVersion
            )
        }

        // Kill an owned child before waiting for the startup coroutine. This
        // makes readiness probes and sleep loops exit promptly.
        await stopOwnedChildIfSafe()
        if hadStartup {
            await waitForStartupToFinish()
        }
        await stopOwnedChildIfSafe()
        activeConnection = nil
        snapshot = RelaySnapshot(
            phase: .stopped,
            owned: false,
            pid: nil,
            baseURL: snapshot.baseURL,
            detail: "Relay is stopped.",
            relayVersion: nil
        )
        appendLog("Relay stopped. External relays are never terminated by this app.")
    }

    private func stopOwnedChildIfSafe() async {
        if let child = process,
           let ownedPID,
           ownedPID == child.processIdentifier,
           child.isRunning {
            // SIGINT matches the relay's tokio::signal::ctrl_c handler.
            kill(ownedPID, SIGINT)
            var waited = 0
            while child.isRunning && waited < 80 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            if child.isRunning {
                // Only the exact process launched by this app may be killed.
                kill(ownedPID, SIGKILL)
            }
        }

        clearLogHandlers()
        process = nil
        ownedPID = nil
    }

    private func waitForStartupToFinish() async {
        guard startupInProgress else { return }
        await withCheckedContinuation { continuation in
            if startupInProgress {
                startupWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func finishStartup() {
        startupInProgress = false
        let waiters = startupWaiters
        startupWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func ensureStartupCurrent(_ generation: UInt64) throws {
        guard generation == startupGeneration else {
            throw RelayStartError.cancelled
        }
    }

    public func restart(settings: AppSettings) async throws -> RelayConnection {
        await stop()
        return try await start(settings: settings)
    }

    private func handleTermination(_ finished: Process) {
        guard let current = process, current === finished else { return }
        let status = finished.terminationStatus
        clearLogHandlers()
        process = nil
        ownedPID = nil
        activeConnection = nil
        if snapshot.phase != .stopping {
            snapshot = RelaySnapshot(
                phase: .failed,
                owned: true,
                pid: nil,
                baseURL: snapshot.baseURL,
                detail: "Relay exited (status \(status)). Check the log for details.",
                relayVersion: nil
            )
            appendLog("Relay exited with status \(status).")
        }
    }

    private func attachLogs(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                self?.appendLog(text)
            }
        }
    }

    private func clearLogHandlers() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
    }

    private func appendLog(_ raw: String) {
        var text = raw
        if let tokens {
            text = text.replacingOccurrences(of: tokens.readToken, with: "[redacted]")
            text = text.replacingOccurrences(of: tokens.ingestToken, with: "[redacted]")
        }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0.prefix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        logs.append(contentsOf: lines)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        while logs.reduce(0, { $0 + $1.utf8.count + 1 }) > 32 * 1024, logs.count > 1 {
            logs.removeFirst()
        }
    }
}
