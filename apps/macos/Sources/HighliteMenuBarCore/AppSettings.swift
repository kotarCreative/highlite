import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var port: Int
    public var allowedOrigins: String
    public var relayBinaryPath: String

    public init(
        port: Int = 8787,
        allowedOrigins: String = "http://localhost:5173,http://127.0.0.1:5173",
        relayBinaryPath: String = ""
    ) {
        self.port = port
        self.allowedOrigins = allowedOrigins
        self.relayBinaryPath = relayBinaryPath
    }

    public var allowedOriginList: [String] {
        allowedOrigins
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    public func validated() throws -> AppSettings {
        guard (1...65_535).contains(port) else {
            throw SettingsValidationError.invalidPort
        }
        _ = try Self.normalizedOrigins(allowedOrigins)
        _ = try Self.validatedPath(relayBinaryPath, label: "Relay binary")
        var copy = self
        copy.allowedOrigins = try Self.normalizedOrigins(allowedOrigins).joined(separator: ",")
        copy.relayBinaryPath = relayBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    public static func normalizedOrigins(_ text: String) throws -> [String] {
        let raw = text
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: [String] = []
        for origin in raw {
            guard var components = URLComponents(string: origin),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host,
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.path.isEmpty || components.path == "/"
            else {
                throw SettingsValidationError.invalidOrigin(origin)
            }
            components.scheme = scheme
            components.path = ""
            guard let normalized = components.string else {
                throw SettingsValidationError.invalidOrigin(origin)
            }
            if !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    public static func validatedPath(_ raw: String, label: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        guard value.utf8.count <= 1024,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r")
        else {
            throw SettingsValidationError.invalidPath(label)
        }
        if value.contains("/"), !value.hasPrefix("/") {
            throw SettingsValidationError.invalidPath(label)
        }
        return value
    }
}

public enum SettingsValidationError: LocalizedError, Equatable {
    case invalidPort
    case invalidOrigin(String)
    case invalidPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "Choose a local port from 1 to 65535."
        case .invalidOrigin(let origin):
            return "\(origin) is not a valid HTTP origin. Use scheme, host, and optional port only."
        case .invalidPath(let label):
            return "\(label) must be empty, a command name, or an absolute path (up to 1024 characters)."
        }
    }
}

public final class AppSettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.highlite.menubar.app-settings") {
        self.defaults = defaults
        self.key = key
    }

    public func load(environmentFile: URL) -> AppSettings {
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            var settings = stored
            settings.relayBinaryPath = stored.relayBinaryPath
            return settings
        }
        return Self.defaultsFromEnvironment(environmentFile: environmentFile)
    }

    public func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }

    public static func defaultsFromEnvironment(environmentFile: URL) -> AppSettings {
        guard let text = try? String(contentsOf: environmentFile, encoding: .utf8) else {
            return AppSettings()
        }
        let values = RelayEnvironment.parseValues(text)
        var settings = AppSettings()
        if let bind = values[RelayEnvironment.bindKey],
           let portText = bind.split(separator: ":").last,
           let port = Int(portText),
           (1...65_535).contains(port) {
            settings.port = port
        }
        if let origins = values[RelayEnvironment.originsKey], !origins.isEmpty {
            settings.allowedOrigins = origins
        }
        return settings
    }
}
