import Combine
import Foundation
import HighliteMenuBarCore

struct ReviewRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let sessionTitle: String
    let run: OpenCodeRun
    let key: String

    init(sessionId: String, sessionTitle: String, run: OpenCodeRun, key: String) {
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.run = run
        self.key = key
    }

    var targets: [OpenCodeCandidate] {
        OpenCodeReviewTargeting.eligibleCandidates(run)
    }

    var pinnedTargetID: String? {
        OpenCodeReviewTargeting.pinnedTargetID(run)
    }

    var allowsTargetOverride: Bool {
        OpenCodeReviewTargeting.allowsTargetOverride(run)
    }

    var defaultTargetId: String? {
        OpenCodeReviewTargeting.defaultTargetID(run)
    }

    func canSubmit(targetSessionID: String) -> Bool {
        OpenCodeReviewTargeting.canSubmit(run, targetSessionID: targetSessionID)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var relay: RelaySnapshot
    @Published var dashboardSection: DashboardSection = .overview
    @Published var relayLogs: [String] = []
    @Published var sessions: [SessionMetadata] = []
    @Published var activity: [ActivityItem] = []
    @Published var providers: ProviderListResponse?
    @Published var jiraConfig: JiraRecipeInfoResponse?
    @Published var openCodeConfig: OpenCodeRecipeInfoResponse?
    @Published var selectedSessionID: String?
    @Published var jiraRuns: [String: JiraRun] = [:]
    @Published var openCodeRuns: [String: OpenCodeRun] = [:]
    @Published var pendingRuns: [String: OpenCodeRun] = [:]
    @Published var pendingCount = 0
    @Published var reviewRequest: ReviewRequest?
    @Published var reviewError: String?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var discovery: OpenCodeDiscoverResponse?
    @Published var cliValidationMessage: String?
    @Published var jiraConnection: JiraConnectionResponse?
    @Published var jiraIssueTypes: [JiraChoice] = []
    @Published var activityError: String?
    @Published var busy: Set<String> = []
    @Published var lastPollAt: Date?

    private let supervisor: RelaySupervisor
    private let settingsStore: AppSettingsStore
    private let paths: RelayPaths
    private let defaults: UserDefaults
    private var client: RelayClient?
    private var pollTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var notifiedKeys: Set<String> = []
    private var deferredKeys: Set<String> = []
    private var relayIntentGeneration: UInt64 = 0
    private var shuttingDown = false
    private let historyKey = "com.highlite.menubar.review-history"
    private let historyLimit = 500

    init(
        paths: RelayPaths = .standard(),
        settingsStore: AppSettingsStore = AppSettingsStore(),
        supervisor: RelaySupervisor? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.paths = paths
        self.settingsStore = settingsStore
        self.supervisor = supervisor ?? RelaySupervisor(paths: paths)
        self.defaults = defaults
        let loaded = settingsStore.load(environmentFile: paths.envFile)
        self.settings = loaded
        self.relay = RelaySnapshot.stopped(baseURL: loaded.baseURL)
        loadReviewHistory()
    }

    var selectedSession: SessionMetadata? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.sessionId == selectedSessionID }
    }

    var jiraRunForSelection: JiraRun? {
        guard let selectedSessionID else { return nil }
        return jiraRuns[selectedSessionID]
    }

    var openCodeRunForSelection: OpenCodeRun? {
        guard let selectedSessionID else { return nil }
        return openCodeRuns[selectedSessionID]
    }

    var readToken: String? { supervisor.tokens?.readToken }
    var ingestToken: String? { supervisor.tokens?.ingestToken }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    func clearError() {
        errorMessage = nil
    }

    func setNotice(_ text: String?) {
        notice = text
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !shuttingDown else { return }
        relay = supervisor.snapshot
        relayLogs = supervisor.logs
        supervisor.$snapshot
            .sink { [weak self] value in
                Task { @MainActor in self?.relay = value }
            }
            .store(in: &cancellables)
        supervisor.$logs
            .sink { [weak self] value in
                Task { @MainActor in self?.relayLogs = value }
            }
            .store(in: &cancellables)

        await startRelay()
        startPolling()
    }

    func shutdown() async {
        shuttingDown = true
        relayIntentGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        await supervisor.stop()
        client = nil
        relay = supervisor.snapshot
    }

    func startRelay() async {
        guard !shuttingDown, !isBusy("relay"), !isBusy("settings") else { return }
        busy.insert("relay")
        relayIntentGeneration &+= 1
        let intent = relayIntentGeneration
        defer { busy.remove("relay") }
        do {
            let connection = try await supervisor.start(settings: settings)
            guard intent == relayIntentGeneration, supervisor.snapshot.isRunning else {
                return
            }
            let newClient = RelayClient()
            try await newClient.configure(
                baseURL: connection.baseURL,
                readToken: connection.tokens.readToken
            )
            guard intent == relayIntentGeneration, supervisor.snapshot.isRunning else {
                return
            }
            client = newClient
            errorMessage = nil
            await refreshAll()
        } catch {
            guard intent == relayIntentGeneration else { return }
            client = nil
            relay = supervisor.snapshot
            if let startError = error as? RelayStartError,
               case .cancelled = startError {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func stopRelay() async {
        relayIntentGeneration &+= 1
        await supervisor.stop()
        client = nil
        relay = supervisor.snapshot
        if reviewRequest != nil {
            deferCurrentReview()
        }
        pendingCount = 0
        pendingRuns.removeAll()
        activityError = nil
    }

    func applySettings(portText: String, origins: String, binaryPath: String) async -> Bool {
        guard !isBusy("settings") else { return false }
        busy.insert("settings")
        defer { busy.remove("settings") }
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = SettingsValidationError.invalidPort.localizedDescription
            return false
        }
        let candidate = AppSettings(port: port, allowedOrigins: origins, relayBinaryPath: binaryPath)
        let validated: AppSettings
        do {
            validated = try candidate.validated()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        guard RelayBinaryLocator.locate(configuredPath: validated.relayBinaryPath) != nil else {
            errorMessage = RelayStartError.relayNotFound.localizedDescription
            return false
        }

        let previousSettings = settings
        relayIntentGeneration &+= 1
        let intent = relayIntentGeneration
        let previousWasRunning = supervisor.snapshot.isRunning
        var newClient: RelayClient?

        let outcome = await RelaySettingsTransaction.run(
            preflight: {
                guard RelayBinaryLocator.locate(configuredPath: validated.relayBinaryPath) != nil else {
                    throw RelayStartError.relayNotFound
                }
            },
            apply: {
                let connection = try await supervisor.restart(settings: validated)
                let candidateClient = RelayClient()
                try await candidateClient.configure(
                    baseURL: connection.baseURL,
                    readToken: connection.tokens.readToken
                )
                newClient = candidateClient
            },
            persist: {
                guard intent == relayIntentGeneration else {
                    throw RelayStartError.cancelled
                }
                try settingsStore.save(validated)
            },
            rollback: {
                guard intent == relayIntentGeneration else {
                    await supervisor.stop()
                    self.client = nil
                    return
                }
                if previousWasRunning {
                    let connection = try await supervisor.restart(settings: previousSettings)
                    let restored = RelayClient()
                    try await restored.configure(
                        baseURL: connection.baseURL,
                        readToken: connection.tokens.readToken
                    )
                    self.client = restored
                } else {
                    await supervisor.stop()
                    self.client = nil
                }
            }
        )

        guard intent == relayIntentGeneration else {
            relay = supervisor.snapshot
            return false
        }
        relay = supervisor.snapshot
        if outcome.applied {
            settings = validated
            client = newClient
            errorMessage = nil
            notice = "Settings saved."
            await refreshAll()
            return true
        }

        var message = outcome.failure ?? "Settings could not be applied."
        if let rollbackFailure = outcome.rollbackFailure,
           !rollbackFailure.isEmpty {
            client = nil
            message += " Restoring the previous relay also failed: \(rollbackFailure)"
        }
        errorMessage = message
        return false
    }

    // MARK: - Refresh

    func refreshAll() async {
        await refreshSessions()
        await refreshProviders()
        await refreshJiraConfig()
        await refreshOpenCodeConfig()
        await refreshActivity()
    }

    func refreshSessions() async {
        guard let client else { return }
        do {
            sessions = try await client.listSessions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshProviders() async {
        guard let client else { return }
        do {
            providers = try await client.providers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshJiraConfig() async {
        guard let client else { return }
        do {
            jiraConfig = try await client.jiraRecipe()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshOpenCodeConfig() async {
        guard let client else { return }
        do {
            openCodeConfig = try await client.openCodeRecipe()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshActivity(showErrors: Bool = true) async {
        guard let client else { return }
        do {
            activity = try await client.activity(limit: 100)
            activityError = nil
            lastPollAt = Date()
        } catch {
            if showErrors {
                activityError = error.localizedDescription
            }
        }
    }

    func selectSession(_ id: String) async {
        if !sessions.contains(where: { $0.sessionId == id }) {
            await refreshSessions()
        }
        selectedSessionID = id
        await refreshJiraRun(sessionId: id)
        await refreshOpenCodeRun(sessionId: id)
    }

    func refreshJiraRun(sessionId: String) async {
        guard let client else { return }
        do {
            if let run = try await client.jiraRun(sessionId: sessionId) {
                jiraRuns[sessionId] = run
            } else {
                jiraRuns.removeValue(forKey: sessionId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshOpenCodeRun(sessionId: String) async {
        guard let client else { return }
        do {
            if let run = try await client.openCodeRun(sessionId: sessionId) {
                openCodeRuns[sessionId] = run
                synchronizeReviewIfNeeded(run)
            } else {
                openCodeRuns.removeValue(forKey: sessionId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Providers

    func saveProvider(
        id: String,
        kind: ProviderKind,
        model: String,
        baseURL: String,
        apiKey: String,
        clearApiKey: Bool,
        makeDefault: Bool
    ) async -> String? {
        let providerId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderIdentifier.isValid(providerId) else {
            return "Provider IDs must be 1-64 ASCII letters, digits, hyphens, or underscores."
        }
        let modelValue = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelValue.isEmpty else {
            return "Enter a model name."
        }
        let baseValue = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind.requiresBaseURL, baseValue.isEmpty {
            return "An OpenAI-compatible provider needs a base URL."
        }
        let normalizedBase: String
        do {
            normalizedBase = try ProviderEndpointValidation.normalize(baseValue, kind: kind)
        } catch {
            return error.localizedDescription
        }
        let existing = providers?.providers.first { $0.id == providerId }
        let explicitlyClearingKey = kind == .openaiCompatible && clearApiKey
        if let existing, existing.hasApiKey, !explicitlyClearingKey,
           apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !ProviderCredentialPolicy.canPreserveStoredKey(
               originalKind: existing.kind,
               originalBaseURL: existing.baseUrl,
               newKind: kind,
               newBaseURL: normalizedBase
           ) {
            return "Changing the provider kind or endpoint requires re-entering the API key. The stored key was not silently reused."
        }
        guard let client else {
            return RelayAPIError.notConfigured.localizedDescription
        }
        busy.insert("provider-save")
        defer { busy.remove("provider-save") }
        do {
            let request = ProviderSaveRequest(
                kind: kind,
                model: modelValue,
                baseUrl: baseValue.isEmpty ? nil : normalizedBase,
                apiKey: explicitlyClearingKey
                    ? nil
                    : (apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : apiKey),
                clearApiKey: explicitlyClearingKey,
                makeDefault: makeDefault
            )
            providers = try await client.saveProvider(id: providerId, request: request)
            errorMessage = nil
            notice = "Provider saved. Credentials are not verified by saving."
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func makeProviderDefault(id: String) async {
        guard let client else { return }
        busy.insert("provider-default")
        defer { busy.remove("provider-default") }
        do {
            providers = try await client.setDefaultProvider(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectProvider(id: String) async {
        guard let client else { return }
        busy.insert("provider-disconnect")
        defer { busy.remove("provider-disconnect") }
        do {
            providers = try await client.disconnectProvider(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Jira

    func saveJira(settings candidate: JiraSettings, apiToken: String) async -> Bool {
        guard let client else {
            errorMessage = RelayAPIError.notConfigured.localizedDescription
            return false
        }
        let normalized = JiraInputNormalization.settings(candidate)
        let prompt = normalized.prompt
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 16 * 1024,
              !prompt.contains("\0")
        else {
            errorMessage = "Jira instructions must be non-empty and no larger than 16 KiB."
            return false
        }
        let project = normalized.jira.projectKey
        guard project.unicodeScalars.allSatisfy({
            CharacterSet.uppercaseLetters.union(CharacterSet(charactersIn: "0123456789_")).contains($0)
        }), !project.isEmpty else {
            errorMessage = "Choose a Jira project key with uppercase letters, digits, or underscores."
            return false
        }
        guard !normalized.jira.issueTypeId.isEmpty,
              normalized.jira.issueTypeId.allSatisfy({ $0.isNumber })
        else {
            errorMessage = "Choose a Jira issue type."
            return false
        }
        guard normalized.jira.extraFields.objectValue != nil else {
            errorMessage = RelayModelError.invalidJSONObject.localizedDescription
            return false
        }
        if normalized.enabled, let providers, providers.defaultProvider == nil {
            errorMessage = "Configure a default AI provider before enabling the Jira recipe."
            return false
        }
        busy.insert("jira-save")
        defer { busy.remove("jira-save") }
        do {
            let token = JiraInputNormalization.apiToken(apiToken)
            let info = try await client.updateJiraRecipe(settings: normalized, apiToken: token)
            if let existing = jiraConfig {
                jiraConfig = JiraRecipeInfoResponse(
                    managementEnabled: existing.managementEnabled,
                    recipe: info
                )
            } else {
                jiraConfig = JiraRecipeInfoResponse(managementEnabled: true, recipe: info)
            }
            errorMessage = nil
            notice = "Jira recipe saved. The API token remains in the relay's private configuration."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func testJiraConnection(
        siteUrl: String,
        email: String,
        apiToken: String,
        projectKey: String?
    ) async -> Bool {
        guard let client else { return false }
        busy.insert("jira-connection")
        defer { busy.remove("jira-connection") }
        do {
            let token = JiraInputNormalization.apiToken(apiToken)
            let response = try await client.testJiraConnection(
                siteUrl: JiraInputNormalization.siteURL(siteUrl),
                email: JiraInputNormalization.email(email),
                apiToken: token,
                projectKey: projectKey.map(JiraInputNormalization.projectKey).flatMap { $0.isEmpty ? nil : $0 }
            )
            jiraConnection = response
            errorMessage = nil
            notice = "Connected as \(response.displayName)."
            return true
        } catch {
            jiraConnection = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadJiraIssueTypes(
        siteUrl: String,
        email: String,
        apiToken: String,
        projectKey: String
    ) async -> Bool {
        guard let client else { return false }
        busy.insert("jira-types")
        defer { busy.remove("jira-types") }
        do {
            let token = JiraInputNormalization.apiToken(apiToken)
            jiraIssueTypes = try await client.jiraIssueTypes(
                siteUrl: JiraInputNormalization.siteURL(siteUrl),
                email: JiraInputNormalization.email(email),
                apiToken: token,
                projectKey: JiraInputNormalization.projectKey(projectKey)
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startJiraDraft(sessionId: String) async {
        guard let client else { return }
        busy.insert("jira-start")
        defer { busy.remove("jira-start") }
        do {
            jiraRuns[sessionId] = try await client.startJiraRun(sessionId: sessionId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveJiraDraft(sessionId: String, revision: Int, draft: JiraDraft) async -> Bool {
        guard let client else { return false }
        busy.insert("jira-draft")
        defer { busy.remove("jira-draft") }
        do {
            jiraRuns[sessionId] = try await client.editJiraDraft(
                sessionId: sessionId,
                revision: revision,
                draft: draft
            )
            errorMessage = nil
            notice = "Draft saved. Review it before publishing."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func publishJira(sessionId: String, revision: Int) async -> Bool {
        guard let client else { return false }
        busy.insert("jira-publish")
        defer { busy.remove("jira-publish") }
        do {
            jiraRuns[sessionId] = try await client.publishJiraRun(
                sessionId: sessionId,
                revision: revision
            )
            errorMessage = nil
            notice = "Jira publication started."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - OpenCode recipe

    func saveOpenCode(settings candidate: OpenCodeSettings) async -> Bool {
        guard let client else {
            errorMessage = RelayAPIError.notConfigured.localizedDescription
            return false
        }
        let directory = candidate.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if directory.isEmpty {
            guard !candidate.enabled else {
                errorMessage = "OpenCode requires an absolute project directory when enabled."
                return false
            }
        } else {
            guard directory.hasPrefix("/"),
                  !directory.contains("\0"),
                  !directory.contains("\n")
            else {
                errorMessage = "OpenCode requires an absolute project directory when enabled."
                return false
            }
        }
        guard !candidate.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate.prompt.utf8.count <= 16 * 1024,
              !candidate.prompt.contains("\0")
        else {
            errorMessage = "OpenCode instructions must be non-empty and no larger than 16 KiB."
            return false
        }
        guard (5...50).contains(candidate.maxCandidates) else {
            errorMessage = "Choose between 5 and 50 candidate sessions."
            return false
        }
        do {
            _ = try OpenCodeLocator.validateConfiguredPath(candidate.opencodePath)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if candidate.enabled, let providers, providers.defaultProvider == nil {
            errorMessage = "Configure a default AI provider before enabling the OpenCode recipe."
            return false
        }

        var normalized = candidate
        normalized.directory = directory
        normalized.opencodePath = normalized.opencodePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        busy.insert("opencode-save")
        defer { busy.remove("opencode-save") }
        do {
            let info = try await client.updateOpenCodeRecipe(settings: normalized)
            if let existing = openCodeConfig {
                openCodeConfig = OpenCodeRecipeInfoResponse(
                    managementEnabled: existing.managementEnabled,
                    recipe: info
                )
            } else {
                openCodeConfig = OpenCodeRecipeInfoResponse(managementEnabled: true, recipe: info)
            }
            errorMessage = nil
            discovery = nil
            notice = "OpenCode recipe saved. Saving does not verify the CLI path."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func validateOpenCodeCLI(path: String, directory: String) async -> Bool {
        busy.insert("opencode-cli")
        defer { busy.remove("opencode-cli") }
        cliValidationMessage = nil
        let configured = path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let executable = OpenCodeLocator.resolveExecutable(configuredPath: configured) else {
            cliValidationMessage = OpenCodeLocatorError.notFound.localizedDescription
            return false
        }
        do {
            let info = try await OpenCodeLocator.probeServerInfo(
                configuredPath: configured,
                workingDirectory: directory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            _ = try OpenCodeLocator.requireSupportedVersion(info)
            cliValidationMessage = "OpenCode \(info.version) responded from \(executable)."
            errorMessage = nil
            return true
        } catch {
            cliValidationMessage = error.localizedDescription
            return false
        }
    }

    func discoverOpenCode(path: String) async -> Bool {
        guard let client else { return false }
        busy.insert("opencode-discover")
        defer { busy.remove("opencode-discover") }
        do {
            let override = path.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let response = try await client.discoverOpenCode(opencodePath: override)
            discovery = response
            errorMessage = nil
            notice = "OpenCode \(response.opencode.version) returned \(response.sessions.count) eligible sessions."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startOpenCodeRun(sessionId: String) async {
        guard let client else { return }
        busy.insert("opencode-start")
        defer { busy.remove("opencode-start") }
        do {
            openCodeRuns[sessionId] = try await client.startOpenCodeRun(sessionId: sessionId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Review and pending suggestions

    func requestReview(run: OpenCodeRun, sessionTitle: String) {
        reviewError = nil
        let key = Self.reviewKey(run)
        rememberNotified(key)
        reviewRequest = ReviewRequest(
            sessionId: run.sessionId,
            sessionTitle: sessionTitle,
            run: run,
            key: key
        )
    }

    func deferCurrentReview() {
        guard let request = reviewRequest else { return }
        rememberDeferred(request.key)
        reviewRequest = nil
        reviewError = nil
        notice = "Suggestion deferred. It remains pending in the relay and in the badge."
    }

    func submitReview(request: ReviewRequest, targetSessionId: String) async {
        guard let client else { return }
        guard request.targets.contains(where: { $0.sessionId == targetSessionId }) else {
            reviewError = "Choose one of the eligible OpenCode sessions."
            return
        }
        if let pinned = request.pinnedTargetID, pinned != targetSessionId {
            reviewError = "This rejected run is pinned to its previous target. Regenerate the suggestion before choosing a different session."
            return
        }
        guard request.canSubmit(targetSessionID: targetSessionId) else {
            reviewError = request.run.promptPreview.isEmpty
                ? "This run has no stored prompt. Regenerate the suggestion."
                : "This target cannot be retried for the current run."
            return
        }
        guard !isBusy("review-submit") else { return }
        busy.insert("review-submit")
        defer { busy.remove("review-submit") }
        reviewError = nil
        do {
            let run = try await client.submitOpenCodeRun(
                sessionId: request.sessionId,
                revision: request.run.revision,
                targetSessionId: targetSessionId
            )
            openCodeRuns[request.sessionId] = run
            rememberNotified(request.key)
            synchronizeReviewIfNeeded(run)
            switch run.status {
            case .failed:
                reviewError = run.error ?? "OpenCode rejected the prompt. Review the run before retrying."
            case .submitting, .queued, .analyzing:
                reviewError = nil
            default:
                break
            }
            await refreshActivity(showErrors: false)
        } catch {
            reviewError = error.localizedDescription
        }
    }

    func reviewNextPending() async {
        await refreshActivity(showErrors: false)
        guard let client else {
            notice = "Connect the relay before reviewing suggestions."
            return
        }
        for item in activity where item.recipe == "opencode" && item.status == "suggested" {
            // Always fetch the run. A cached pendingRuns entry may belong to a
            // previous revision after regeneration or a failed refresh.
            guard let run = await fetchOpenCodeRun(client: client, sessionId: item.sessionId) else {
                continue
            }
            openCodeRuns[item.sessionId] = run
            pendingRuns[item.sessionId] = run
            guard run.status == .suggested else { continue }
            requestReview(run: run, sessionTitle: item.title ?? "Pending suggestion")
            return
        }
        notice = "There are no pending OpenCode suggestions right now."
    }

    func clearNotificationHistory() {
        notifiedKeys.removeAll()
        deferredKeys.removeAll()
        defaults.removeObject(forKey: "\(historyKey).notified")
        defaults.removeObject(forKey: "\(historyKey).deferred")
        notice = "Popup and defer history cleared. Pending runs remain in the relay."
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func pollOnce() async {
        guard let client, relay.isRunning else { return }
        var items: [ActivityItem] = []
        do {
            items = try await client.activity(limit: 100)
            activity = items
            activityError = nil
            lastPollAt = Date()
        } catch {
            if activity.isEmpty {
                activityError = error.localizedDescription
            }
        }

        let suggested = items.filter { $0.recipe == "opencode" && $0.status == "suggested" }
        pendingCount = Set(suggested.map(\.sessionId)).count

        var refreshed: [String: OpenCodeRun] = [:]
        for item in suggested.prefix(12) {
            if let run = await fetchOpenCodeRun(client: client, sessionId: item.sessionId) {
                refreshed[item.sessionId] = run
            }
        }
        if suggested.isEmpty {
            pendingRuns.removeAll()
        } else {
            let suggestedIDs = Set(suggested.map(\.sessionId))
            pendingRuns = pendingRuns.filter { suggestedIDs.contains($0.key) }
            for (sessionID, run) in refreshed {
                pendingRuns[sessionID] = run
            }
        }

        if let selectedSessionID {
            if let jira = await fetchJiraRun(client: client, sessionId: selectedSessionID) {
                jiraRuns[selectedSessionID] = jira
            }
            if let run = await fetchOpenCodeRun(client: client, sessionId: selectedSessionID) {
                openCodeRuns[selectedSessionID] = run
                synchronizeReviewIfNeeded(run)
            }
        }

        if let request = reviewRequest,
           let run = await fetchOpenCodeRun(client: client, sessionId: request.sessionId) {
            openCodeRuns[run.sessionId] = run
            synchronizeReviewIfNeeded(run)
        }

        guard reviewRequest == nil else { return }
        for item in suggested {
            guard let run = refreshed[item.sessionId],
                  run.status == .suggested
            else {
                continue
            }
            let key = Self.reviewKey(run)
            if deferredKeys.contains(key) || notifiedKeys.contains(key) {
                continue
            }
            rememberNotified(key)
            reviewError = nil
            reviewRequest = ReviewRequest(
                sessionId: run.sessionId,
                sessionTitle: item.title ?? "Pending suggestion",
                run: run,
                key: key
            )
            // Do not auto-submit. The review window is a confirmation step.
            return
        }
    }

    // MARK: - Helpers

    private func synchronizeReviewIfNeeded(_ run: OpenCodeRun) {
        guard let current = reviewRequest, current.sessionId == run.sessionId else {
            return
        }
        if current.key == Self.reviewKey(run), current.run.status == run.status {
            return
        }
        switch run.status {
        case .submitted:
            reviewRequest = nil
            reviewError = nil
            notice = "Prompt sent to \(run.opencodeTitle ?? run.opencodeSessionId ?? "OpenCode")."
        case .submitUnknown:
            reviewRequest = nil
            reviewError = nil
            notice = "Delivery is uncertain. Check OpenCode before trying again; the app will not resend automatically."
        case .failed:
            let key = Self.reviewKey(run)
            rememberNotified(key)
            reviewRequest = ReviewRequest(
                sessionId: run.sessionId,
                sessionTitle: current.sessionTitle,
                run: run,
                key: key
            )
            reviewError = run.error ?? "OpenCode rejected the prompt. Review the run before retrying."
        case .suggested, .submitting, .queued, .analyzing:
            let key = Self.reviewKey(run)
            rememberNotified(key)
            reviewRequest = ReviewRequest(
                sessionId: run.sessionId,
                sessionTitle: current.sessionTitle,
                run: run,
                key: key
            )
            reviewError = nil
        }
    }

    static func reviewKey(_ run: OpenCodeRun) -> String {
        "\(run.sessionId)|\(run.revision)|\(run.updatedAtMs)"
    }

    private func fetchJiraRun(client: RelayClient, sessionId: String) async -> JiraRun? {
        do {
            return try await client.jiraRun(sessionId: sessionId)
        } catch {
            return nil
        }
    }

    private func fetchOpenCodeRun(client: RelayClient, sessionId: String) async -> OpenCodeRun? {
        do {
            return try await client.openCodeRun(sessionId: sessionId)
        } catch {
            return nil
        }
    }

    private func loadReviewHistory() {
        notifiedKeys = Set(defaults.stringArray(forKey: "\(historyKey).notified") ?? [])
        deferredKeys = Set(defaults.stringArray(forKey: "\(historyKey).deferred") ?? [])
    }

    private func rememberNotified(_ key: String) {
        notifiedKeys.insert(key)
        let ordered = trimmedHistory(notifiedKeys)
        notifiedKeys = Set(ordered)
        defaults.set(ordered, forKey: "\(historyKey).notified")
    }

    private func rememberDeferred(_ key: String) {
        deferredKeys.insert(key)
        let ordered = trimmedHistory(deferredKeys)
        deferredKeys = Set(ordered)
        defaults.set(ordered, forKey: "\(historyKey).deferred")
    }

    private func trimmedHistory(_ set: Set<String>) -> [String] {
        let ordered = Array(set)
        if ordered.count > historyLimit {
            return Array(ordered.suffix(historyLimit))
        }
        return ordered
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
