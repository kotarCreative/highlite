import Foundation
import XCTest
@testable import HighliteMenuBarCore

func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw XCTSkip("Missing fixture \(name).json")
    }
    return try Data(contentsOf: url)
}

final class RelayModelsTests: XCTestCase {
    func testSessionFixtureDecodes() throws {
        let response = try JSONDecoder().decode(SessionsResponse.self, from: fixtureData("sessions"))
        XCTAssertEqual(response.sessions.count, 2)
        XCTAssertEqual(response.sessions[0].sessionId, "hl-abc123")
        XCTAssertEqual(response.sessions[0].status, .ready)
        XCTAssertEqual(response.sessions[0].pageTitle, "Checkout page")
        XCTAssertEqual(response.sessions[0].durationMs, 42000)
        XCTAssertEqual(response.sessions[1].status, .failed)
        XCTAssertEqual(response.sessions[1].error, "Capture failed")
    }

    func testProvidersFixtureDecodes() throws {
        let response = try JSONDecoder().decode(ProviderListResponse.self, from: fixtureData("providers"))
        XCTAssertTrue(response.enabled)
        XCTAssertEqual(response.defaultProvider, "work")
        XCTAssertEqual(response.providers.count, 2)
        XCTAssertEqual(response.providers[0].kind, .openaiCompatible)
        XCTAssertTrue(response.providers[0].hasApiKey)
        XCTAssertEqual(response.providers[1].kind, .openai)
    }

    func testProviderResponseWithoutEnabledDefaultsTrue() throws {
        let data = Data(#"{"defaultProvider":null,"providers":[]}"#.utf8)
        let response = try JSONDecoder().decode(ProviderListResponse.self, from: data)
        XCTAssertTrue(response.enabled)
        XCTAssertNil(response.defaultProvider)
    }

    func testJiraFixtureDecodesNestedExtraFields() throws {
        let response = try JSONDecoder().decode(JiraRecipeInfoResponse.self, from: fixtureData("jira_recipe"))
        XCTAssertTrue(response.managementEnabled)
        XCTAssertEqual(response.recipe.id, "jira-issue")
        XCTAssertEqual(response.recipe.version, "1.1.0")
        XCTAssertTrue(response.recipe.hasApiToken)
        let settings = try XCTUnwrap(response.recipe.settings)
        XCTAssertEqual(settings.publishMode, .review)
        XCTAssertEqual(settings.jira.projectKey, "TEAM")
        XCTAssertEqual(settings.jira.issueTypeId, "10001")
        let labels = settings.jira.extraFields.objectValue?["labels"]
        XCTAssertEqual(labels, .array([.string("highlite")]))
    }

    func testOpenCodeRunFixtureDecodes() throws {
        let response = try JSONDecoder().decode(OpenCodeRunResponse.self, from: fixtureData("opencode_run"))
        let run = try XCTUnwrap(response.run)
        XCTAssertEqual(run.status, .suggested)
        XCTAssertEqual(run.revision, 1)
        XCTAssertEqual(run.eligibleSessionIds, ["ses_abc", "ses_def"])
        XCTAssertEqual(run.candidates.first?.projectName, "app")
        XCTAssertEqual(run.suggestion?.confidence, .high)
        XCTAssertEqual(run.settings.directory, "/Users/me/work/app")
        XCTAssertNil(run.settings.opencodePath)
        XCTAssertNil(run.messageId)
        XCTAssertTrue(run.status.isReviewable)
    }

    func testActivityFixtureDecodes() throws {
        let response = try JSONDecoder().decode(ActivityResponse.self, from: fixtureData("activity"))
        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].recipe, "opencode")
        XCTAssertEqual(response.items[1].issueKey, "TEAM-123")
    }

    func testServerInfoFixtureDecodesAndVersionChecked() throws {
        let info = try JSONDecoder().decode(OpenCodeServerInfo.self, from: fixtureData("server_info"))
        XCTAssertEqual(info.version, "2.0.32")
        XCTAssertEqual(info.pid, 4242)
        XCTAssertNoThrow(try OpenCodeLocator.requireSupportedVersion(info))
        XCTAssertThrowsError(
            try OpenCodeLocator.requireSupportedVersion(
                OpenCodeServerInfo(version: "1.9.0", pid: nil, urls: nil, paths: nil)
            )
        )
    }

    func testProviderRequestOmitsBlankSecretAndEndpoint() throws {
        let request = ProviderSaveRequest(
            kind: .openai,
            model: "gpt-5",
            baseUrl: "   ",
            apiKey: "  ",
            makeDefault: true
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "openai")
        XCTAssertEqual(object["model"] as? String, "gpt-5")
        XCTAssertNil(object["apiKey"])
        XCTAssertNil(object["baseUrl"])
        XCTAssertEqual(object["clearApiKey"] as? Bool, false)
        XCTAssertEqual(object["makeDefault"] as? Bool, true)
    }

    func testProviderRequestIncludesNonBlankSecret() throws {
        let request = ProviderSaveRequest(
            kind: .openaiCompatible,
            model: "model",
            baseUrl: "https://ai.example.com/v1",
            apiKey: "secret",
            clearApiKey: false,
            makeDefault: false
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "openai-compatible")
        XCTAssertEqual(object["apiKey"] as? String, "secret")
        XCTAssertEqual(object["baseUrl"] as? String, "https://ai.example.com/v1")
    }

    func testJiraConfigRequestOmitsBlankToken() throws {
        let request = JiraRecipeConfigRequest(
            settings: JiraSettings.defaults(),
            apiToken: "   "
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["apiToken"])
        XCTAssertNotNil(object["settings"])
    }

    func testJiraConnectionRequestsOmitBlankToken() throws {
        let connection = JiraConnectionRequest(
            siteUrl: "https://team.atlassian.net",
            email: "person@example.com",
            apiToken: "",
            projectKey: ""
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as? [String: Any]
        )
        XCTAssertNil(object["apiToken"])
        XCTAssertNil(object["projectKey"])
        XCTAssertEqual(object["siteUrl"] as? String, "https://team.atlassian.net")
    }

    func testOpenCodeSettingsEncodesNullPathAndAllFields() throws {
        let settings = OpenCodeSettings()
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["opencodePath"] is NSNull)
        XCTAssertEqual(object["maxCandidates"] as? Int, 30)
        XCTAssertEqual(object["enabled"] as? Bool, false)
        XCTAssertFalse((object["prompt"] as? String ?? "").isEmpty)
    }

    func testOpenCodeDiscoverRequestOmitsBlankPath() throws {
        let request = OpenCodeDiscoverRequest(opencodePath: "  ")
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["opencodePath"])
    }

    func testJSONValueParsingAndObjectRequirement() throws {
        let value = try JSONValue.parse(#"{"labels":["highlite"],"priority":{"id":"2"},"count":3}"#)
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["count"], .int(3))
        XCTAssertEqual(object["priority"], .object(["id": .string("2")]))
        XCTAssertThrowsError(try JSONValue.parseObject("[]"))
        XCTAssertThrowsError(try JSONValue.parse("not json"))
    }

    func testSettingsDefaultsAreUsable() {
        let jira = JiraSettings.defaults()
        XCTAssertFalse(jira.enabled)
        XCTAssertFalse(jira.prompt.isEmpty)
        XCTAssertEqual(jira.publishMode, .review)
        XCTAssertEqual(jira.jira.extraFields, .object([:]))
        XCTAssertFalse(OpenCodeSettings.defaultPrompt.isEmpty)
    }
}
