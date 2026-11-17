import Foundation
import HighliteMenuBarCore
@testable import HighliteMenuBar

/// App model fixture with isolated preferences, token storage, and temporary
/// paths so window and layout tests never touch the real app support directory
/// or Keychain.
@MainActor
struct TestAppModel {
    let model: AppModel
    private let suiteName: String
    private let defaults: UserDefaults
    private let root: URL

    init() {
        suiteName = "HighliteMenuBarTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HighliteMenuBarTests-\(UUID().uuidString)", isDirectory: true)
        let paths = RelayPaths(root: root)
        model = AppModel(
            paths: paths,
            settingsStore: AppSettingsStore(defaults: defaults, key: "app-settings"),
            supervisor: RelaySupervisor(paths: paths, tokenStore: InMemoryTokenStore()),
            defaults: defaults
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

final class InMemoryTokenStore: RelayTokenStoring {
    private var values: [String: String] = [:]

    func string(for account: String) throws -> String? {
        values[account]
    }

    func set(_ value: String, for account: String) throws {
        values[account] = value
    }

    func remove(_ account: String) throws {
        values.removeValue(forKey: account)
    }
}

func makeSession(id: String = "session-1") -> SessionMetadata {
    SessionMetadata(
        sessionId: id,
        status: .ready,
        receivedAtMs: 1_700_000_000_000,
        bytes: 1_024,
        pageTitle: "Example capture",
        pageUrl: "https://example.test/page",
        durationMs: 5_000,
        summary: "A short capture summary.",
        statusUrl: "http://127.0.0.1:8787/v1/sessions/\(id)",
        bundleUrl: "http://127.0.0.1:8787/v1/sessions/\(id)/bundle"
    )
}

@MainActor
func makeReviewRequest() -> ReviewRequest {
    let candidate = OpenCodeCandidate(
        sessionId: "opencode-1",
        title: "Existing OpenCode session",
        directory: "/tmp/project",
        projectId: "project-1",
        projectName: "Project",
        createdAtMs: 0,
        updatedAtMs: 0
    )
    let suggestion = OpenCodeSuggestion(
        sessionId: candidate.sessionId,
        title: candidate.title,
        directory: candidate.directory,
        projectName: candidate.projectName,
        confidence: .high,
        reason: "Metadata matches the configured project directory."
    )
    let run = OpenCodeRun(
        sessionId: "capture-1",
        recipe: "opencode",
        recipeVersion: "1",
        status: .suggested,
        settings: OpenCodeSettings(enabled: true, directory: candidate.directory),
        eligibleSessionIds: [candidate.sessionId],
        candidates: [candidate],
        suggestion: suggestion,
        promptPreview: "Review the capture at https://example.test/page.",
        revision: 1,
        createdAtMs: 0,
        updatedAtMs: 0
    )
    return ReviewRequest(
        sessionId: "capture-1",
        sessionTitle: "Example capture",
        run: run,
        key: "capture-1-1-0"
    )
}
