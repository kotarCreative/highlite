import Darwin
import Foundation
import Security

public struct RelayPaths: Equatable, Sendable {
    public var supportDirectory: URL
    public var envFile: URL
    public var configDirectory: URL
    public var dataDirectory: URL

    public init(root: URL) {
        supportDirectory = root
        envFile = root.appendingPathComponent("relay.env", isDirectory: false)
        configDirectory = root.appendingPathComponent("config", isDirectory: true)
        dataDirectory = root.appendingPathComponent("data", isDirectory: true)
    }

    public static func standard(fileManager: FileManager = .default) -> RelayPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return RelayPaths(root: base.appendingPathComponent("Highlite", isDirectory: true))
    }
}

public struct RelayTokens: Equatable, Sendable {
    public var readToken: String
    public var ingestToken: String

    public init(readToken: String, ingestToken: String) {
        self.readToken = readToken
        self.ingestToken = ingestToken
    }
}

public enum RelayEnvironmentError: LocalizedError, Equatable {
    case cannotCreateDirectory(String)
    case cannotRead(String)
    case cannotWrite(String)
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let path):
            return "Could not create the private relay directory at \(path)."
        case .cannotRead(let path):
            return "Could not read the relay environment file at \(path)."
        case .cannotWrite(let path):
            return "Could not write the relay environment file at \(path)."
        case .keychain(let message):
            return message
        }
    }
}

/// Private relay environment handling.
///
/// The environment file is mode 0600 inside a mode 0700 directory. Existing
/// token lines and unrelated relay settings are preserved; the app only fills
/// missing tokens and updates the origins value it owns.
public enum RelayEnvironment {
    public static let readTokenKey = "HIGHLITE_RELAY_READ_TOKEN"
    public static let ingestTokenKey = "HIGHLITE_RELAY_INGEST_TOKEN"
    public static let originsKey = "HIGHLITE_RELAY_ALLOWED_ORIGINS"
    public static let hostsKey = "HIGHLITE_RELAY_ALLOWED_HOSTS"
    public static let bindKey = "HIGHLITE_RELAY_BIND"

    public static func prepare(
        paths: RelayPaths,
        allowedOrigins: [String],
        allowedHosts: [String] = [],
        tokenStore: RelayTokenStoring = KeychainStore(),
        fileManager: FileManager = .default
    ) throws -> RelayTokens {
        try prepareDirectories(paths, fileManager: fileManager)
        let existing = try readValues(paths: paths, fileManager: fileManager)
        let readToken = try chooseToken(
            account: RelayTokenAccount.read,
            envKey: readTokenKey,
            values: existing,
            tokenStore: tokenStore
        )
        let ingestToken = try chooseToken(
            account: RelayTokenAccount.ingest,
            envKey: ingestTokenKey,
            values: existing,
            tokenStore: tokenStore
        )
        let tokens = RelayTokens(readToken: readToken, ingestToken: ingestToken)
        try writeEnvFile(
            paths: paths,
            tokens: tokens,
            allowedOrigins: allowedOrigins,
            allowedHosts: allowedHosts,
            fileManager: fileManager
        )
        return tokens
    }

    public static func prepareDirectories(
        _ paths: RelayPaths,
        fileManager: FileManager = .default
    ) throws {
        for directory in [paths.supportDirectory, paths.configDirectory, paths.dataDirectory] {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            } catch {
                throw RelayEnvironmentError.cannotCreateDirectory(directory.path)
            }
        }
    }

    public static func readValues(
        paths: RelayPaths,
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        guard fileManager.fileExists(atPath: paths.envFile.path) else {
            return [:]
        }
        let text: String
        do {
            text = try String(contentsOf: paths.envFile, encoding: .utf8)
        } catch {
            throw RelayEnvironmentError.cannotRead(paths.envFile.path)
        }
        return parseValues(text)
    }

    public static func writeEnvFile(
        paths: RelayPaths,
        tokens: RelayTokens,
        allowedOrigins: [String],
        allowedHosts: [String] = [],
        fileManager: FileManager = .default
    ) throws {
        if isSymbolicLink(paths.envFile, fileManager: fileManager) {
            throw RelayEnvironmentError.cannotWrite(paths.envFile.path)
        }
        let existingText: String
        if fileManager.fileExists(atPath: paths.envFile.path) {
            do {
                existingText = try String(contentsOf: paths.envFile, encoding: .utf8)
            } catch {
                throw RelayEnvironmentError.cannotRead(paths.envFile.path)
            }
        } else {
            existingText = "# Highlite relay configuration generated by HighliteMenuBar.\n"
        }

        let existingValues = parseValues(existingText)
        var lines = existingText.components(separatedBy: .newlines)
        if lines.last == "" {
            lines.removeLast()
        }

        // Preserve valid existing tokens (including multiple valid relay
        // tokens), but replace invalid/empty values with the selected token so
        // the app and relay cannot stay permanently mismatched.
        lines = upsert(
            key: readTokenKey,
            value: mergedTokenValue(existing: existingValues[readTokenKey], selected: tokens.readToken),
            in: lines,
            onlyWhenMissing: false
        )
        lines = upsert(
            key: ingestTokenKey,
            value: mergedTokenValue(existing: existingValues[ingestTokenKey], selected: tokens.ingestToken),
            in: lines,
            onlyWhenMissing: false
        )
        lines = upsert(
            key: originsKey,
            value: allowedOrigins.joined(separator: ","),
            in: lines,
            onlyWhenMissing: false
        )
        if !allowedHosts.isEmpty {
            var hosts = (existingValues[hostsKey] ?? "")
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for host in allowedHosts where !hosts.contains(host) {
                hosts.append(host)
            }
            lines = upsert(
                key: hostsKey,
                value: hosts.joined(separator: ","),
                in: lines,
                onlyWhenMissing: false
            )
        }

        let text = lines.joined(separator: "\n") + "\n"
        do {
            try writePrivateFile(text, to: paths.envFile)
        } catch {
            throw RelayEnvironmentError.cannotWrite(paths.envFile.path)
        }
    }

    public static func parseValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let entry = parseLine(line) else { continue }
            values[entry.key] = entry.value
        }
        return values
    }

    private static func chooseToken(
        account: String,
        envKey: String,
        values: [String: String],
        tokenStore: RelayTokenStoring
    ) throws -> String {
        if let stored = validTokenList(values[envKey]).first {
            try? tokenStore.set(stored, for: account)
            return stored
        }
        let keychainValue: String?
        do {
            keychainValue = try tokenStore.string(for: account)
        } catch {
            throw RelayEnvironmentError.keychain(
                "Could not read the relay token from Keychain."
            )
        }
        if let keychainValue, validToken(keychainValue) {
            return keychainValue
        }
        let generated = try generateToken()
        do {
            try tokenStore.set(generated, for: account)
        } catch {
            throw RelayEnvironmentError.keychain(
                "Could not save the relay token in Keychain."
            )
        }
        return generated
    }

    private static func validTokenList(_ value: String?) -> [String] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { validToken($0) && seen.insert($0).inserted }
    }

    private static func mergedTokenValue(existing: String?, selected: String) -> String {
        let valid = validTokenList(existing)
        if !valid.isEmpty {
            return valid.joined(separator: ",")
        }
        return selected
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.utf8.count <= 4096
            && !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw RelayEnvironmentError.keychain("Could not generate a secure relay token.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func upsert(
        key: String,
        value: String,
        in lines: [String],
        onlyWhenMissing: Bool
    ) -> [String] {
        var result: [String] = []
        var sawKey = false
        var wroteValue = false
        for line in lines {
            guard let entry = parseLine(line), entry.key == key else {
                result.append(line)
                continue
            }
            sawKey = true
            if onlyWhenMissing && !entry.value.isEmpty {
                // Keep an existing non-empty setting byte-for-byte.
                result.append(line)
                wroteValue = true
                continue
            }
            if value.isEmpty || wroteValue {
                // Empty means remove. Later duplicate keys are removed.
                continue
            }
            result.append("\(key)=\(encodeValue(value))")
            wroteValue = true
        }
        if !sawKey, !value.isEmpty {
            result.append("\(key)=\(encodeValue(value))")
        }
        return result
    }

    private static func parseLine(_ line: String) -> (key: String, value: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("export ") {
            trimmed = String(trimmed.dropFirst("export ".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var value = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            value = String(value.dropFirst().dropLast())
        } else if let comment = value.firstIndex(of: "#") {
            value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
        }
        return (key, value)
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func writePrivateFile(
        _ text: String,
        to url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let bytes = Array(text.utf8)
        var descriptor = temporary.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw RelayEnvironmentError.cannotWrite(url.path)
        }
        var cleanup = true
        defer {
            if descriptor >= 0 {
                _ = close(descriptor)
            }
            if cleanup {
                _ = temporary.path.withCString { unlink($0) }
            }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw RelayEnvironmentError.cannotWrite(url.path)
        }
        let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard wroteAll, fsync(descriptor) == 0 else {
            throw RelayEnvironmentError.cannotWrite(url.path)
        }
        guard close(descriptor) == 0 else {
            descriptor = -1
            throw RelayEnvironmentError.cannotWrite(url.path)
        }
        descriptor = -1
        let renamed = temporary.path.withCString { source in
            url.path.withCString { destination in
                rename(source, destination)
            }
        }
        guard renamed == 0 else {
            throw RelayEnvironmentError.cannotWrite(url.path)
        }
        cleanup = false
    }

    private static func encodeValue(_ value: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@-+*,"
        )
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
