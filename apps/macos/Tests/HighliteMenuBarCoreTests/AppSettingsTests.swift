import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class AppSettingsTests: XCTestCase {
    func testDefaultSettingsAllowLocalDemoOrigins() throws {
        let settings = AppSettings()
        XCTAssertEqual(settings.port, 8787)
        XCTAssertEqual(settings.baseURL.absoluteString, "http://127.0.0.1:8787")
        let origins = try AppSettings.normalizedOrigins(settings.allowedOrigins)
        XCTAssertEqual(origins, ["http://localhost:5173", "http://127.0.0.1:5173"])
        XCTAssertNoThrow(try settings.validated())
    }

    func testInvalidPortIsRejected() {
        XCTAssertThrowsError(try AppSettings(port: 0).validated())
        XCTAssertThrowsError(try AppSettings(port: 70_000).validated())
    }

    func testOriginsAreNormalizedAndValidated() throws {
        let origins = try AppSettings.normalizedOrigins(
            "https://Example.com:443/, http://localhost:3000, https://Example.com:443,"
        )
        XCTAssertEqual(origins.count, 2)
        XCTAssertTrue(origins.contains("http://localhost:3000"))
        XCTAssertThrowsError(try AppSettings.normalizedOrigins("https://example.com/a/path"))
        XCTAssertThrowsError(try AppSettings.normalizedOrigins("file:///tmp"))
        XCTAssertThrowsError(try AppSettings.normalizedOrigins("https://user:pass@example.com"))
    }

    func testPathsRequireAbsoluteWhenTheyLookLikePaths() throws {
        XCTAssertEqual(try AppSettings.validatedPath("", label: "Binary"), "")
        XCTAssertEqual(try AppSettings.validatedPath("opencode", label: "Binary"), "opencode")
        XCTAssertEqual(
            try AppSettings.validatedPath("/opt/homebrew/bin/highlite-relay", label: "Binary"),
            "/opt/homebrew/bin/highlite-relay"
        )
        XCTAssertThrowsError(try AppSettings.validatedPath("bin/relay", label: "Binary"))
        XCTAssertThrowsError(try AppSettings.validatedPath("/tmp/a\nb", label: "Binary"))
    }

    func testSettingsStoreRoundTrips() throws {
        let suite = "com.highlite.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        let settings = AppSettings(
            port: 9999,
            allowedOrigins: "https://app.example.com",
            relayBinaryPath: "/opt/homebrew/bin/highlite-relay"
        )
        try store.save(settings)
        let loaded = store.load(environmentFile: URL(fileURLWithPath: "/nonexistent/relay.env"))
        XCTAssertEqual(loaded, settings)
    }

    func testFirstLoadImportsPortAndOriginsFromEnvironmentFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = directory.appendingPathComponent("relay.env")
        let text = """
        HIGHLITE_RELAY_BIND=127.0.0.1:9091
        HIGHLITE_RELAY_ALLOWED_ORIGINS=http://localhost:3000,https://app.example.com
        HIGHLITE_RELAY_READ_TOKEN=existing
        """
        try Data(text.utf8).write(to: env)

        let suite = "com.highlite.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        let loaded = store.load(environmentFile: env)
        XCTAssertEqual(loaded.port, 9091)
        XCTAssertEqual(loaded.allowedOrigins, "http://localhost:3000,https://app.example.com")
        XCTAssertEqual(loaded.relayBinaryPath, "")
    }
}
