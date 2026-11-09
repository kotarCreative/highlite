import Foundation
import Darwin

public struct OpenCodeServerPaths: Codable, Hashable, Sendable {
    public var tmp: String?
}

public struct OpenCodeServerInfo: Codable, Hashable, Sendable {
    public var version: String
    public var pid: Int?
    public var urls: [String]?
    public var paths: OpenCodeServerPaths?
}

public enum OpenCodeLocatorError: LocalizedError, Equatable {
    case invalidPath
    case notFound
    case launchFailed
    case timeout
    case failed(Int)
    case http(Int)
    case unreadable
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "The OpenCode path must be an absolute path, a command name, or empty."
        case .notFound:
            return "OpenCode was not found. Set its path or install it in a standard location."
        case .launchFailed:
            return "OpenCode could not be launched."
        case .timeout:
            return "OpenCode did not respond within 20 seconds."
        case .failed(let status):
            return "opencode api server.info exited with status \(status)."
        case .http(let status):
            return "OpenCode rejected the request with HTTP \(status)."
        case .unreadable:
            return "OpenCode returned an unreadable server response."
        case .unsupportedVersion(let version):
            return "Highlite requires OpenCode major version 2; found \(version)."
        }
    }
}

/// Resolves the `opencode` executable without hardcoding authentication.
///
/// The app uses this for an explicit local CLI sanity check. Relay recipe work
/// still goes through the relay, which invokes the authenticated CLI itself.
public enum OpenCodeLocator {
    public static func validateConfiguredPath(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= 1024,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r")
        else {
            throw OpenCodeLocatorError.invalidPath
        }
        if value.contains("/"), !value.hasPrefix("/") {
            throw OpenCodeLocatorError.invalidPath
        }
        return value
    }

    public static func augmentedPATH(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/.opencode/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/opt/node/bin",
            "/usr/local/bin",
        ]
        var segments = preferred
        if let existing = environment["PATH"] {
            segments.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        segments.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])

        var seen = Set<String>()
        var result: [String] = []
        for segment in segments where !segment.isEmpty && !seen.contains(segment) {
            seen.insert(segment)
            result.append(segment)
        }
        return result.joined(separator: ":")
    }

    public static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base.filter { key, _ in
            !key.hasPrefix("HIGHLITE_RELAY_") && key != "HIGHLITE_CONFIG_DIR"
        }
        environment["PATH"] = augmentedPATH(environment: base)
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// Returns an executable absolute path, or nil when the command cannot be found.
    public static func resolveExecutable(
        configuredPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let chosen: String
        if let configuredPath, !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let validated = try? validateConfiguredPath(configuredPath) else { return nil }
            chosen = validated
        } else if let fromEnvironment = environment["HIGHLITE_OPENCODE_BIN"],
                  !fromEnvironment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let validated = try? validateConfiguredPath(fromEnvironment) else { return nil }
            chosen = validated
        } else {
            chosen = "opencode"
        }

        let fileManager = FileManager.default
        if chosen.contains("/") {
            return fileManager.isExecutableFile(atPath: chosen) ? chosen : nil
        }
        for directory in augmentedPATH(environment: environment).split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(chosen, isDirectory: false)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func probeServerInfo(
        configuredPath: String?,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 20,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> OpenCodeServerInfo {
        guard let executable = resolveExecutable(
            configuredPath: configuredPath,
            environment: environment
        ) else {
            throw OpenCodeLocatorError.notFound
        }
        let childEnvironment = childEnvironment(base: environment)
        let cwd = workingDirectory.flatMap { path -> String? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) else {
                return nil
            }
            return trimmed
        }
        return try await Task.detached(priority: .userInitiated) {
            try runServerInfo(
                executable: executable,
                environment: childEnvironment,
                workingDirectory: cwd,
                timeout: timeout
            )
        }.value
    }

    public static func requireSupportedVersion(_ info: OpenCodeServerInfo) throws -> OpenCodeServerInfo {
        let major = info.version.split(separator: ".").first.flatMap { Int($0) }
        guard major == 2 else {
            throw OpenCodeLocatorError.unsupportedVersion(info.version)
        }
        return info
    }

    private static func runServerInfo(
        executable: String,
        environment: [String: String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) throws -> OpenCodeServerInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["api", "server.info"]
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw OpenCodeLocatorError.launchFailed
        }

        let stdout = OutputBuffer(limit: 2 * 1024 * 1024)
        let stderr = OutputBuffer(limit: 64 * 1024)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            readAvailable(from: stdoutPipe.fileHandleForReading, into: stdout)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            readAvailable(from: stderrPipe.fileHandleForReading, into: stderr)
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            timedOut = true
            kill(process.processIdentifier, SIGTERM)
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 3)

        if timedOut {
            throw OpenCodeLocatorError.timeout
        }
        let status = process.terminationStatus
        guard status == 0 else {
            let text = String(decoding: stderr.data, as: UTF8.self)
            if let code = httpStatus(in: text) {
                throw OpenCodeLocatorError.http(code)
            }
            throw OpenCodeLocatorError.failed(Int(status))
        }
        let data = stdout.data
        guard !data.isEmpty,
              let info = try? JSONDecoder().decode(OpenCodeServerInfo.self, from: data)
        else {
            throw OpenCodeLocatorError.unreadable
        }
        return info
    }

    private static func readAvailable(from handle: FileHandle, into buffer: OutputBuffer) {
        while true {
            do {
                guard let data = try handle.read(upToCount: 16 * 1024), !data.isEmpty else {
                    return
                }
                buffer.append(data)
            } catch {
                return
            }
        }
    }

    private static func httpStatus(in text: String) -> Int? {
        let pattern = "HTTP ([0-9]{3})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var storage = Data()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, limit - storage.count)
            if remaining > 0 {
                storage.append(data.prefix(remaining))
            }
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
