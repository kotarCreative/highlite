import Foundation

public enum ProviderIdentifier {
    /// Mirrors the relay's provider-id rule exactly.
    public static func isValid(_ identifier: String) -> Bool {
        guard (1...64).contains(identifier.utf8.count) else { return false }
        return identifier.utf8.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2D
                || byte == 0x5F
        }
    }
}

public enum ProviderEndpointError: LocalizedError, Equatable {
    case invalidURL
    case insecureRemoteURL
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed
    case customEndpointRequiredKind

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The base URL must be a valid URL."
        case .insecureRemoteURL:
            return "Provider URLs must use HTTPS, or HTTP only for a loopback host."
        case .credentialsNotAllowed:
            return "Provider URLs cannot contain a username or password."
        case .queryOrFragmentNotAllowed:
            return "Provider URLs cannot contain a query or fragment."
        case .customEndpointRequiredKind:
            return "Custom base URLs require the OpenAI-compatible provider kind."
        }
    }
}

public enum ProviderEndpointValidation {
    public static let openAIDefault = "https://api.openai.com/v1"
    public static let anthropicDefault = "https://api.anthropic.com/v1"

    public static func defaultBaseURL(for kind: ProviderKind) -> String {
        switch kind {
        case .openai:
            return openAIDefault
        case .anthropic:
            return anthropicDefault
        case .openaiCompatible:
            return ""
        }
    }

    /// Returns a normalized URL without a trailing slash.
    public static func normalize(_ raw: String, kind: ProviderKind) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? defaultBaseURL(for: kind) : trimmed
        guard !value.isEmpty else {
            throw ProviderEndpointError.invalidURL
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty
        else {
            throw ProviderEndpointError.invalidURL
        }
        if scheme == "http" {
            guard isLoopbackHost(host) else {
                throw ProviderEndpointError.insecureRemoteURL
            }
        }
        guard components.user == nil, components.password == nil else {
            throw ProviderEndpointError.credentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw ProviderEndpointError.queryOrFragmentNotAllowed
        }
        if kind != .openaiCompatible,
           trimTrailingSlashes(value) != defaultBaseURL(for: kind) {
            throw ProviderEndpointError.customEndpointRequiredKind
        }

        components.scheme = scheme
        components.host = host.lowercased()
        guard let normalized = components.url?.absoluteString else {
            throw ProviderEndpointError.invalidURL
        }
        return trimTrailingSlashes(normalized)
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let value = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if value == "localhost" || value == "::1" {
            return true
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({ UInt8(String($0)) != nil })
        else {
            return false
        }
        return parts.first == "127"
    }

    private static func trimTrailingSlashes(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/"), result.count > 1 {
            result.removeLast()
        }
        return result
    }
}

public enum ProviderCredentialPolicy {
    /// The relay reuses a stored key only when both provider kind and normalized
    /// endpoint are unchanged. The editor and save path use the same rule.
    public static func canPreserveStoredKey(
        originalKind: ProviderKind,
        originalBaseURL: String,
        newKind: ProviderKind,
        newBaseURL: String
    ) -> Bool {
        guard originalKind == newKind else { return false }
        let original = (try? ProviderEndpointValidation.normalize(originalBaseURL, kind: originalKind))
            ?? originalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (try? ProviderEndpointValidation.normalize(newBaseURL, kind: newKind))
            ?? newBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return original == candidate
    }
}

public enum JiraInputNormalization {
    public static func siteURL(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/"), result.count > 1 {
            result.removeLast()
        }
        return result
    }

    public static func email(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func projectKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func issueTypeID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func apiToken(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func target(_ target: JiraTarget) -> JiraTarget {
        JiraTarget(
            siteUrl: siteURL(target.siteUrl),
            email: email(target.email),
            projectKey: projectKey(target.projectKey),
            issueTypeId: issueTypeID(target.issueTypeId),
            extraFields: target.extraFields
        )
    }

    public static func settings(_ settings: JiraSettings) -> JiraSettings {
        JiraSettings(
            enabled: settings.enabled,
            autoDraft: settings.autoDraft,
            publishMode: settings.publishMode,
            includeImages: settings.includeImages,
            prompt: settings.prompt,
            jira: target(settings.jira)
        )
    }
}
