import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class ValidationTests: XCTestCase {
    func testProviderIdentifierMatchesRelayRule() {
        XCTAssertTrue(ProviderIdentifier.isValid("work"))
        XCTAssertTrue(ProviderIdentifier.isValid("work-1_A"))
        XCTAssertTrue(ProviderIdentifier.isValid(String(repeating: "a", count: 64)))
        XCTAssertFalse(ProviderIdentifier.isValid(""))
        XCTAssertFalse(ProviderIdentifier.isValid(String(repeating: "a", count: 65)))
        XCTAssertFalse(ProviderIdentifier.isValid("team.work"))
        XCTAssertFalse(ProviderIdentifier.isValid("team work"))
        XCTAssertFalse(ProviderIdentifier.isValid("téam"))
    }

    func testProviderEndpointValidation() throws {
        XCTAssertEqual(
            try ProviderEndpointValidation.normalize(" https://ai.example.com/v1/ ", kind: .openaiCompatible),
            "https://ai.example.com/v1"
        )
        XCTAssertEqual(
            try ProviderEndpointValidation.normalize("http://localhost:11434/v1", kind: .openaiCompatible),
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            try ProviderEndpointValidation.normalize("http://127.0.0.1:8080", kind: .openaiCompatible),
            "http://127.0.0.1:8080"
        )
        XCTAssertEqual(
            try ProviderEndpointValidation.normalize("", kind: .openai),
            ProviderEndpointValidation.openAIDefault
        )
        XCTAssertThrowsError(
            try ProviderEndpointValidation.normalize("http://ai.example.com/v1", kind: .openaiCompatible)
        ) { error in
            XCTAssertEqual(error as? ProviderEndpointError, .insecureRemoteURL)
        }
        XCTAssertThrowsError(
            try ProviderEndpointValidation.normalize(
                "https://user:pass@ai.example.com/v1",
                kind: .openaiCompatible
            )
        ) { error in
            XCTAssertEqual(error as? ProviderEndpointError, .credentialsNotAllowed)
        }
        XCTAssertThrowsError(
            try ProviderEndpointValidation.normalize(
                "https://ai.example.com/v1?x=1",
                kind: .openaiCompatible
            )
        ) { error in
            XCTAssertEqual(error as? ProviderEndpointError, .queryOrFragmentNotAllowed)
        }
        XCTAssertThrowsError(
            try ProviderEndpointValidation.normalize(
                "https://ai.example.com/v1#fragment",
                kind: .openaiCompatible
            )
        ) { error in
            XCTAssertEqual(error as? ProviderEndpointError, .queryOrFragmentNotAllowed)
        }
        XCTAssertThrowsError(
            try ProviderEndpointValidation.normalize(
                "https://custom.example.com/v1",
                kind: .openai
            )
        ) { error in
            XCTAssertEqual(error as? ProviderEndpointError, .customEndpointRequiredKind)
        }
    }

    func testCredentialPolicyRequiresSameKindAndNormalizedEndpoint() {
        XCTAssertTrue(
            ProviderCredentialPolicy.canPreserveStoredKey(
                originalKind: .openaiCompatible,
                originalBaseURL: "https://ai.example.com/v1/",
                newKind: .openaiCompatible,
                newBaseURL: "https://ai.example.com/v1"
            )
        )
        XCTAssertFalse(
            ProviderCredentialPolicy.canPreserveStoredKey(
                originalKind: .openaiCompatible,
                originalBaseURL: "https://ai.example.com/v1",
                newKind: .openaiCompatible,
                newBaseURL: "https://ai.example.com/v2"
            )
        )
        XCTAssertFalse(
            ProviderCredentialPolicy.canPreserveStoredKey(
                originalKind: .openai,
                originalBaseURL: ProviderEndpointValidation.openAIDefault,
                newKind: .anthropic,
                newBaseURL: ProviderEndpointValidation.anthropicDefault
            )
        )
    }

    func testJiraInputNormalization() {
        let target = JiraTarget(
            siteUrl: " https://team.atlassian.net/ ",
            email: " person@example.com ",
            projectKey: " TEAM ",
            issueTypeId: " 10001 "
        )
        let normalized = JiraInputNormalization.target(target)
        XCTAssertEqual(normalized.siteUrl, "https://team.atlassian.net")
        XCTAssertEqual(normalized.email, "person@example.com")
        XCTAssertEqual(normalized.projectKey, "TEAM")
        XCTAssertEqual(normalized.issueTypeId, "10001")
        XCTAssertNil(JiraInputNormalization.apiToken("  "))
        XCTAssertEqual(JiraInputNormalization.apiToken(" token "), "token")
    }

    func testOpenCodeAnalysisInputsMatchRelayRules() {
        let base = OpenCodeSettings(
            enabled: true,
            autoDraft: true,
            directory: "/tmp/app",
            prompt: "Choose",
            opencodePath: nil,
            maxCandidates: 30
        )
        var changed = base
        changed.prompt = "Choose another"
        XCTAssertTrue(changed.analysisInputsChanged(comparedTo: base))
        changed = base
        changed.enabled = false
        XCTAssertFalse(changed.analysisInputsChanged(comparedTo: base))
        changed = base
        changed.maxCandidates = 20
        XCTAssertTrue(changed.analysisInputsChanged(comparedTo: base))
    }

    func testRetryIsPinnedToRejectedTargetNotOriginalSuggestion() {
        var run = makeRun(
            status: .failed,
            suggestionID: "ses_original",
            opencodeSessionID: "ses_retry"
        )
        XCTAssertEqual(OpenCodeReviewTargeting.pinnedTargetID(run), "ses_retry")
        XCTAssertEqual(OpenCodeReviewTargeting.defaultTargetID(run), "ses_retry")
        XCTAssertFalse(OpenCodeReviewTargeting.allowsTargetOverride(run))
        XCTAssertTrue(OpenCodeReviewTargeting.canSubmit(run, targetSessionID: "ses_retry"))
        XCTAssertFalse(OpenCodeReviewTargeting.canSubmit(run, targetSessionID: "ses_original"))

        run = makeRun(status: .suggested, suggestionID: "ses_original", opencodeSessionID: nil)
        XCTAssertNil(OpenCodeReviewTargeting.pinnedTargetID(run))
        XCTAssertEqual(OpenCodeReviewTargeting.defaultTargetID(run), "ses_original")
        XCTAssertTrue(OpenCodeReviewTargeting.allowsTargetOverride(run))
        XCTAssertTrue(OpenCodeReviewTargeting.canSubmit(run, targetSessionID: "ses_other"))

        run = makeRun(status: .submitting, suggestionID: "ses_original", opencodeSessionID: "ses_retry")
        XCTAssertFalse(OpenCodeReviewTargeting.canSubmit(run, targetSessionID: "ses_retry"))

        run = makeRun(status: .failed, suggestionID: "ses_original", opencodeSessionID: nil)
        XCTAssertFalse(OpenCodeReviewTargeting.canSubmit(run, targetSessionID: "ses_original"))
    }

    func testPinnedTargetMissingFromCandidatesCannotBeSubmitted() {
        let run = makeRun(
            status: .failed,
            suggestionID: "ses_original",
            opencodeSessionID: "ses_missing",
            candidates: [("ses_original", "Original"), ("ses_other", "Other")]
        )
        XCTAssertEqual(OpenCodeReviewTargeting.pinnedTargetID(run), "ses_missing")
        XCTAssertFalse(OpenCodeReviewTargeting.canSubmit(run, targetSessionID: "ses_missing"))
    }

    func testSettingsTransactionPreflightFailureNeverStopsOrPersists() async {
        let outcome = await runPreflightFailureScenario()
        XCTAssertFalse(outcome.result.applied)
        XCTAssertFalse(outcome.result.persisted)
        XCTAssertFalse(outcome.stopped)
        XCTAssertFalse(outcome.persisted)
        XCTAssertFalse(outcome.rolledBack)
        XCTAssertEqual(
            outcome.result.failure,
            RelayStartError.relayNotFound.localizedDescription
        )
    }

    @MainActor
    private func runPreflightFailureScenario() async -> (
        result: RelaySettingsTransactionResult,
        stopped: Bool,
        persisted: Bool,
        rolledBack: Bool
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-settings-transaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing-relay").path
        let settings = AppSettings(relayBinaryPath: missing)
        var stopped = false
        var persisted = false
        var rolledBack = false

        let result = await RelaySettingsTransaction.run(
            preflight: {
                guard RelayBinaryLocator.locate(configuredPath: settings.relayBinaryPath) != nil else {
                    throw RelayStartError.relayNotFound
                }
            },
            apply: {
                stopped = true
            },
            persist: {
                persisted = true
            },
            rollback: {
                rolledBack = true
            }
        )
        return (result, stopped, persisted, rolledBack)
    }

    func testSettingsTransactionRollsBackWhenApplyOrPersistFails() async {
        let outcome = await runRollbackScenario()
        XCTAssertFalse(outcome.applyFailure.applied)
        XCTAssertFalse(outcome.applyPersisted)
        XCTAssertTrue(outcome.applyRolledBack)
        XCTAssertFalse(outcome.persistFailure.applied)
        XCTAssertFalse(outcome.persistPersisted)
        XCTAssertTrue(outcome.persistRolledBack)
    }

    @MainActor
    private func runRollbackScenario() async -> (
        applyFailure: RelaySettingsTransactionResult,
        applyPersisted: Bool,
        applyRolledBack: Bool,
        persistFailure: RelaySettingsTransactionResult,
        persistPersisted: Bool,
        persistRolledBack: Bool
    ) {
        var persisted = false
        var rolledBack = false
        let applyFailure = await RelaySettingsTransaction.run(
            preflight: {},
            apply: { throw RelayStartError.portConflict("occupied") },
            persist: { persisted = true },
            rollback: { rolledBack = true }
        )
        let applyPersisted = persisted
        let applyRolledBack = rolledBack

        persisted = false
        rolledBack = false
        let persistFailure = await RelaySettingsTransaction.run(
            preflight: {},
            apply: {},
            persist: { throw CocoaError(.fileWriteUnknown) },
            rollback: { rolledBack = true }
        )
        return (
            applyFailure,
            applyPersisted,
            applyRolledBack,
            persistFailure,
            persisted,
            rolledBack
        )
    }

    private func makeRun(
        status: OpenCodeRunStatus,
        suggestionID: String?,
        opencodeSessionID: String?,
        candidates: [(String, String)] = [("ses_original", "Original"), ("ses_retry", "Retry"), ("ses_other", "Other")]
    ) -> OpenCodeRun {
        let allCandidates = candidates.map { pair in
            OpenCodeCandidate(
                sessionId: pair.0,
                title: pair.1,
                directory: "/tmp/app",
                projectId: "prj_1",
                projectName: "app",
                createdAtMs: 1_000,
                updatedAtMs: 2_000
            )
        }
        let suggestion: OpenCodeSuggestion?
        if let suggestionID {
            suggestion = OpenCodeSuggestion(
                sessionId: suggestionID,
                title: "Original",
                directory: "/tmp/app",
                projectName: "app",
                confidence: .high,
                reason: "Matched"
            )
        } else {
            suggestion = nil
        }
        var eligibleSessionIds = allCandidates.map(\.sessionId)
        if let opencodeSessionID, !eligibleSessionIds.contains(opencodeSessionID) {
            eligibleSessionIds.append(opencodeSessionID)
        }
        return OpenCodeRun(
            sessionId: "hl-1",
            recipe: "opencode",
            recipeVersion: "1.0.0",
            status: status,
            settings: OpenCodeSettings(
                enabled: true,
                directory: "/tmp/app",
                prompt: "Choose",
                maxCandidates: 30
            ),
            provider: nil,
            eligibleSessionIds: eligibleSessionIds,
            candidates: allCandidates,
            suggestion: suggestion,
            promptPreview: "Exact prompt",
            opencodeSessionId: opencodeSessionID,
            revision: 2,
            createdAtMs: 1_000,
            updatedAtMs: 3_000
        )
    }
}
