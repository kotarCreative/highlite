import Foundation

public final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The relay is loopback-only. Never follow a redirect to another host.
        completionHandler(nil)
    }
}

/// Typed, authenticated loopback client for the Highlite relay.
///
/// Redirects are rejected, cookies are disabled, and errors never include
/// request bodies, prompts, or bearer tokens.
public actor RelayClient {
    private var baseURL: URL?
    private var readToken: String?
    private var ingestToken: String?
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(session: URLSession? = nil) {
        if let session {
            self.urlSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 45
            configuration.waitsForConnectivity = false
            self.urlSession = URLSession(
                configuration: configuration,
                delegate: NoRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
        }
    }

    public func configure(
        baseURL: URL,
        readToken: String,
        ingestToken: String? = nil
    ) throws {
        guard Self.isLoopbackHTTP(baseURL), !readToken.isEmpty else {
            throw RelayAPIError.invalidEndpoint
        }
        if let ingestToken, ingestToken.isEmpty {
            throw RelayAPIError.invalidEndpoint
        }
        self.baseURL = baseURL
        self.readToken = readToken
        self.ingestToken = ingestToken
    }

    public func clearConfiguration() {
        baseURL = nil
        readToken = nil
        ingestToken = nil
    }

    public var configuredBaseURL: URL? { baseURL }

    public static func isLoopbackHTTP(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    // MARK: - Health and sessions

    public func health(timeout: TimeInterval = 3) async throws -> RelayHealth {
        let data = try await perform(
            method: "GET",
            path: "/healthz",
            query: [],
            body: nil,
            authorization: .none,
            contentType: "application/json",
            timeout: timeout
        )
        return try decode(RelayHealth.self, from: data)
    }

    public func listSessions(timeout: TimeInterval = 15) async throws -> [SessionMetadata] {
        let response: SessionsResponse = try await get(
            "/v1/sessions",
            query: [],
            timeout: timeout
        )
        return response.sessions
    }

    public func session(id: String, timeout: TimeInterval = 15) async throws -> SessionMetadata {
        try await get("/v1/sessions/\(Self.pathSegment(id))", query: [], timeout: timeout)
    }

    /// Uploads a still capture to the local relay's ZIP ingest endpoint. This is
    /// the same endpoint and manifest contract used by browser captures.
    public func ingestCapture(
        _ bundle: NativeCaptureBundle,
        timeout: TimeInterval = 60
    ) async throws -> SessionMetadata {
        let data = try await perform(
            method: "POST",
            path: "/v1/sessions",
            query: [],
            body: bundle.archive,
            authorization: .ingest,
            contentType: "application/zip",
            timeout: timeout
        )
        return try decode(SessionMetadata.self, from: data)
    }

    /// Uploads a native screen recording archive to the same local ingest
    /// endpoint. Video archives are much larger than still captures, so the
    /// default timeout is longer; the relay's own upload limit still applies.
    public func ingestRecording(
        _ bundle: NativeRecordingBundle,
        timeout: TimeInterval = 600
    ) async throws -> SessionMetadata {
        let data = try await perform(
            method: "POST",
            path: "/v1/sessions",
            query: [],
            body: bundle.archive,
            authorization: .ingest,
            contentType: "application/zip",
            timeout: timeout
        )
        return try decode(SessionMetadata.self, from: data)
    }

    // MARK: - Providers

    public func providers() async throws -> ProviderListResponse {
        try await get("/v1/providers", query: [])
    }

    public func saveProvider(id: String, request: ProviderSaveRequest) async throws -> ProviderListResponse {
        try await post(
            "/v1/providers/\(Self.pathSegment(id))",
            body: request,
            timeout: 20
        )
    }

    public func setDefaultProvider(id: String) async throws -> ProviderListResponse {
        try await post(
            "/v1/providers/\(Self.pathSegment(id))/default",
            body: Optional<EmptyBody>.none,
            timeout: 20
        )
    }

    public func disconnectProvider(id: String) async throws -> ProviderListResponse {
        try await post(
            "/v1/providers/\(Self.pathSegment(id))/disconnect",
            body: Optional<EmptyBody>.none,
            timeout: 20
        )
    }

    // MARK: - Jira recipe

    public func jiraRecipe() async throws -> JiraRecipeInfoResponse {
        try await get("/v1/recipes/jira-issue", query: [])
    }

    public func updateJiraRecipe(
        settings: JiraSettings,
        apiToken: String?
    ) async throws -> JiraRecipeInfo {
        try await post(
            "/v1/recipes/jira-issue",
            body: JiraRecipeConfigRequest(settings: settings, apiToken: apiToken),
            timeout: 30
        )
    }

    public func testJiraConnection(
        siteUrl: String,
        email: String,
        apiToken: String?,
        projectKey: String?
    ) async throws -> JiraConnectionResponse {
        try await post(
            "/v1/recipes/jira-issue/connection",
            body: JiraConnectionRequest(
                siteUrl: siteUrl,
                email: email,
                apiToken: apiToken,
                projectKey: projectKey
            ),
            timeout: 40
        )
    }

    public func jiraIssueTypes(
        siteUrl: String,
        email: String,
        apiToken: String?,
        projectKey: String
    ) async throws -> [JiraChoice] {
        let response: JiraIssueTypesResponse = try await post(
            "/v1/recipes/jira-issue/issue-types",
            body: JiraIssueTypesRequest(
                siteUrl: siteUrl,
                email: email,
                apiToken: apiToken,
                projectKey: projectKey
            ),
            timeout: 40
        )
        return response.issueTypes
    }

    public func jiraRun(sessionId: String) async throws -> JiraRun? {
        let response: JiraRunResponse = try await get(
            "/v1/sessions/\(Self.pathSegment(sessionId))/recipes/jira-issue",
            query: []
        )
        return response.run
    }

    public func startJiraRun(sessionId: String) async throws -> JiraRun {
        try await post(
            "/v1/sessions/\(Self.pathSegment(sessionId))/recipes/jira-issue",
            body: Optional<EmptyBody>.none,
            timeout: 20
        )
    }

    public func editJiraDraft(sessionId: String, revision: Int, draft: JiraDraft) async throws -> JiraRun {
        try await post(
            "/v1/sessions/\(Self.pathSegment(sessionId))/recipes/jira-issue/draft",
            body: JiraDraftRequest(revision: revision, draft: draft),
            timeout: 20
        )
    }

    public func publishJiraRun(sessionId: String, revision: Int) async throws -> JiraRun {
        try await post(
            "/v1/sessions/\(Self.pathSegment(sessionId))/recipes/jira-issue/publish",
            body: JiraPublishRequest(revision: revision),
            timeout: 40
        )
    }

    // MARK: - OpenCode recipe

    public func openCodeRecipe() async throws -> OpenCodeRecipeInfoResponse {
        try await get("/v1/recipes/opencode", query: [])
    }

    public func updateOpenCodeRecipe(settings: OpenCodeSettings) async throws -> OpenCodeRecipeInfo {
        try await post(
            "/v1/recipes/opencode",
            body: OpenCodeRecipeConfigRequest(settings: settings),
            timeout: 20
        )
    }

    public func discoverOpenCode(opencodePath: String?) async throws -> OpenCodeDiscoverResponse {
        try await post(
            "/v1/recipes/opencode/discover",
            body: OpenCodeDiscoverRequest(opencodePath: opencodePath),
            timeout: 30
        )
    }

    public func openCodeRun(sessionId: String) async throws -> OpenCodeRun? {
        let response: OpenCodeRunResponse = try await get(
            "/v1/sessions/\(Self.pathSegment(sessionId))/recipes/opencode",
            query: []
        )
        return response.run
    }

    public func startOpenCodeRun(sessionId: String) async throws -> OpenCodeRun {
        try await post(
            "/v1/sessions/\(Self.pathSegment(sessionId))/recipes/opencode",
            body: Optional<EmptyBody>.none,
            timeout: 30
        )
    }

    public func submitOpenCodeRun(
        sessionId: String,
        revision: Int,
        targetSessionId: String
    ) async throws -> OpenCodeRun {
        try await post(
            "/v1/sessions/\(Self.pathSegment(sessionId))/recipes/opencode/submit",
            body: OpenCodeSubmitRequest(
                revision: revision,
                sessionId: targetSessionId,
                confirm: true
            ),
            timeout: 40
        )
    }

    // MARK: - Activity

    public func activity(limit: Int = 25) async throws -> [ActivityItem] {
        let bounded = min(max(limit, 1), 100)
        let response: ActivityResponse = try await get(
            "/v1/activity",
            query: [URLQueryItem(name: "limit", value: String(bounded))]
        )
        return response.items
    }

    // MARK: - Requests

    private struct EmptyBody: Encodable {}

    private enum Authorization: Equatable {
        case none
        case read
        case ingest
    }

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem],
        timeout: TimeInterval = 15
    ) async throws -> T {
        let data = try await perform(
            method: "GET",
            path: path,
            query: query,
            body: nil,
            authorization: .read,
            contentType: "application/json",
            timeout: timeout
        )
        return try decode(T.self, from: data)
    }

    private func post<Body: Encodable, T: Decodable>(
        _ path: String,
        body: Body?,
        timeout: TimeInterval
    ) async throws -> T {
        let encoded: Data?
        if let body {
            encoded = try encoder.encode(body)
        } else {
            encoded = nil
        }
        let data = try await perform(
            method: "POST",
            path: path,
            query: [],
            body: encoded,
            authorization: .read,
            contentType: "application/json",
            timeout: timeout
        )
        return try decode(T.self, from: data)
    }

    private func perform(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        authorization: Authorization,
        contentType: String,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let baseURL else { throw RelayAPIError.notConfigured }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw RelayAPIError.invalidEndpoint }

        let token: String?
        switch authorization {
        case .none:
            token = nil
        case .read:
            token = readToken
        case .ingest:
            token = ingestToken
        }
        if authorization != .none, token?.isEmpty != false {
            throw RelayAPIError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw RelayAPIError.timeout
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw RelayAPIError.network("The relay is not reachable at \(baseURL.absoluteString).")
            default:
                throw RelayAPIError.network("Could not reach the relay.")
            }
        } catch {
            throw RelayAPIError.network("Could not reach the relay.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw RelayAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.errorMessage(
                from: data,
                status: http.statusCode,
                authorization: authorization
            )
            throw RelayAPIError.http(status: http.statusCode, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RelayAPIError.decoding
        }
    }

    private static func errorMessage(
        from data: Data,
        status: Int,
        authorization: Authorization
    ) -> String {
        if status == 401 {
            switch authorization {
            case .ingest:
                return "The relay rejected the stored ingest token. It may belong to a different relay."
            case .read:
                return "The relay rejected the stored read token. It may belong to a different relay."
            case .none:
                break
            }
        }
        if let response = try? JSONDecoder().decode(RelayErrorEnvelope.self, from: data) {
            let cleaned = response.error
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return String(cleaned.prefix(500))
            }
        }
        return "Relay returned HTTP \(status)."
    }

    private static func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private struct RelayErrorEnvelope: Decodable {
        var error: String
    }
}
