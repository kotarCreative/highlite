import Foundation

public enum SiteEmbedSnippetError: LocalizedError, Equatable {
    case invalidRelayURL
    case invalidIngestToken
    case invalidAssetPath

    public var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            return "The relay URL must be an HTTP or HTTPS URL without credentials, a query, or a fragment."
        case .invalidIngestToken:
            return "The ingest token is empty or contains unsupported control characters."
        case .invalidAssetPath:
            return "The SDK asset path is empty, too long, or contains unsupported control characters."
        }
    }
}

/// Builds the script-tag integration shown in the README, with the local
/// relay's ingest endpoint and token filled in. The asset path stays explicit
/// because the SDK is served from each site rather than a published CDN.
public struct SiteEmbedSnippet: Equatable, Sendable {
    /// Matches the example asset path in the repository README. Sites that
    /// serve the built IIFE elsewhere can pass a different path or URL.
    public static let defaultAssetPath = "/assets/highlite.iife.js"

    public let assetPath: String
    public let relayBaseURL: URL
    public let ingestToken: String
    private let endpointURL: URL

    public init(
        assetPath: String = SiteEmbedSnippet.defaultAssetPath,
        relayBaseURL: URL,
        ingestToken: String
    ) throws {
        let trimmedAssetPath = assetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAssetPath.isEmpty,
              trimmedAssetPath.utf8.count <= 4096,
              !trimmedAssetPath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw SiteEmbedSnippetError.invalidAssetPath
        }

        guard let endpoint = Self.ingestEndpoint(for: relayBaseURL) else {
            throw SiteEmbedSnippetError.invalidRelayURL
        }

        guard !ingestToken.isEmpty,
              ingestToken.utf8.count <= 4096,
              !ingestToken.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw SiteEmbedSnippetError.invalidIngestToken
        }

        self.assetPath = trimmedAssetPath
        self.relayBaseURL = relayBaseURL
        self.ingestToken = ingestToken
        self.endpointURL = endpoint
    }

    /// The relay ingest URL used by the SDK. This matches `RelayClient`'s
    /// canonical `/v1/sessions` path rather than appending to the base path.
    public var endpoint: URL { endpointURL }

    public var html: String {
        """
        <script defer src="\(Self.escapeHTMLAttribute(assetPath))"></script>
        <script>
          window.addEventListener('load', () => {
            window.Highlite.createHighlite({
              ui: 'floating',
              capture: { microphone: true, frames: 'prompt', interactions: true },
              relay: {
                endpoint: \(Self.javaScriptString(endpoint.absoluteString)),
                token: \(Self.javaScriptString(ingestToken)),
              },
            });
          });
        </script>
        """
    }

    private static func ingestEndpoint(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return nil
        }

        components.scheme = scheme
        components.path = "/v1/sessions"
        return components.url
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func javaScriptString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for character in value.unicodeScalars {
            switch character.value {
            case 0x5C:
                escaped.append("\\\\")
            case 0x22:
                escaped.append("\\\"")
            case 0x0A:
                escaped.append("\\n")
            case 0x0D:
                escaped.append("\\r")
            case 0x09:
                escaped.append("\\t")
            case 0x3C:
                escaped.append("\\u003c")
            case 0x3E:
                escaped.append("\\u003e")
            case 0x26:
                escaped.append("\\u0026")
            case 0x2028:
                escaped.append("\\u2028")
            case 0x2029:
                escaped.append("\\u2029")
            default:
                escaped.unicodeScalars.append(character)
            }
        }
        escaped.append("\"")
        return escaped
    }
}
