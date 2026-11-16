import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class OpenCodeLocatorTests: XCTestCase {
    func testConfiguredPathValidation() throws {
        XCTAssertNil(try OpenCodeLocator.validateConfiguredPath(nil))
        XCTAssertNil(try OpenCodeLocator.validateConfiguredPath("   "))
        XCTAssertEqual(try OpenCodeLocator.validateConfiguredPath("opencode"), "opencode")
        XCTAssertEqual(
            try OpenCodeLocator.validateConfiguredPath("/opt/homebrew/bin/opencode"),
            "/opt/homebrew/bin/opencode"
        )
        XCTAssertThrowsError(try OpenCodeLocator.validateConfiguredPath("./opencode"))
        XCTAssertThrowsError(try OpenCodeLocator.validateConfiguredPath("bin/opencode"))
        XCTAssertThrowsError(try OpenCodeLocator.validateConfiguredPath("/tmp/open\ncode"))
        XCTAssertThrowsError(
            try OpenCodeLocator.validateConfiguredPath("/" + String(repeating: "a", count: 1100))
        )
    }

    func testAugmentedPathIncludesCommonOpenCodeLocationsWithoutDuplicates() {
        let environment = [
            "HOME": "/Users/tester",
            "PATH": "/opt/homebrew/bin:/usr/bin:/custom/bin",
        ]
        let path = OpenCodeLocator.augmentedPATH(environment: environment)
        let segments = path.split(separator: ":").map(String.init)
        XCTAssertTrue(segments.contains("/Users/tester/.opencode/bin"))
        XCTAssertTrue(segments.contains("/opt/homebrew/bin"))
        XCTAssertTrue(segments.contains("/usr/local/bin"))
        XCTAssertTrue(segments.contains("/custom/bin"))
        XCTAssertEqual(segments.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }

    func testChildEnvironmentRemovesRelaySecretsAndSetsNoColor() {
        let base = [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin",
            "HIGHLITE_RELAY_READ_TOKEN": "secret",
            "HIGHLITE_RELAY_INGEST_TOKEN": "secret2",
            "HIGHLITE_CONFIG_DIR": "/tmp/config",
            "KEEP": "yes",
        ]
        let child = OpenCodeLocator.childEnvironment(base: base)
        XCTAssertNil(child["HIGHLITE_RELAY_READ_TOKEN"])
        XCTAssertNil(child["HIGHLITE_RELAY_INGEST_TOKEN"])
        XCTAssertNil(child["HIGHLITE_CONFIG_DIR"])
        XCTAssertEqual(child["KEEP"], "yes")
        XCTAssertEqual(child["NO_COLOR"], "1")
        XCTAssertTrue(child["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    func testResolveAbsoluteExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = OpenCodeLocator.resolveExecutable(
            configuredPath: executable.path,
            environment: [:]
        )
        XCTAssertEqual(resolved, executable.path)
    }

    func testResolveFromEnvironmentAndPATH() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let fromPATH = OpenCodeLocator.resolveExecutable(
            configuredPath: nil,
            environment: ["PATH": directory.path, "HOME": directory.path],
            isExecutable: { $0 == executable.path }
        )
        XCTAssertEqual(fromPATH, executable.path)

        let fromEnvironment = OpenCodeLocator.resolveExecutable(
            configuredPath: nil,
            environment: [
                "PATH": "/usr/bin",
                "HOME": directory.path,
                "HIGHLITE_OPENCODE_BIN": executable.path,
            ]
        )
        XCTAssertEqual(fromEnvironment, executable.path)
    }

    func testResolveMissingCommandReturnsNil() {
        var candidates: [String] = []
        XCTAssertNil(
            OpenCodeLocator.resolveExecutable(
                configuredPath: nil,
                environment: ["PATH": "/nonexistent", "HOME": "/tmp"],
                isExecutable: { path in
                    candidates.append(path)
                    return false
                }
            )
        )
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/opencode"))
        XCTAssertTrue(candidates.contains("/nonexistent/opencode"))
        XCTAssertTrue(candidates.allSatisfy { $0.hasSuffix("/opencode") })
    }

    func testResolvePrefersStandardLocationOverPATH() {
        let preferred = "/opt/homebrew/bin/opencode"
        let fromPATH = "/custom/bin/opencode"
        XCTAssertEqual(
            OpenCodeLocator.resolveExecutable(
                configuredPath: nil,
                environment: ["PATH": "/custom/bin", "HOME": "/Users/tester"],
                isExecutable: { $0 == preferred || $0 == fromPATH }
            ),
            preferred
        )
    }

    func testProbeRunsCLIAndParsesServerInfo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        let script = """
        #!/bin/sh
        cat <<'EOF'
        {"version":"2.0.32","pid":123,"paths":{"tmp":"/tmp/opencode"}}
        EOF
        """
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data(script.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let info = try await OpenCodeLocator.probeServerInfo(
            configuredPath: executable.path,
            timeout: 5,
            environment: ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(info.version, "2.0.32")
        XCTAssertEqual(info.pid, 123)
        XCTAssertNoThrow(try OpenCodeLocator.requireSupportedVersion(info))
    }

    func testProbeClassifiesHTTPFailureWithoutLeakingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        let script = """
        #!/bin/sh
        echo "HTTP 401" >&2
        echo "secret raw output" >&2
        exit 1
        """
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data(script.utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        do {
            _ = try await OpenCodeLocator.probeServerInfo(
                configuredPath: executable.path,
                timeout: 5,
                environment: ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
            )
            XCTFail("Expected an HTTP failure")
        } catch let error as OpenCodeLocatorError {
            XCTAssertEqual(error, .http(401))
            XCTAssertFalse(error.localizedDescription.contains("secret raw output"))
        }
    }

    func testUnsupportedMajorVersionIsRejected() {
        XCTAssertThrowsError(
            try OpenCodeLocator.requireSupportedVersion(
                OpenCodeServerInfo(version: "1.15.0", pid: nil, urls: nil, paths: nil)
            )
        )
        XCTAssertThrowsError(
            try OpenCodeLocator.requireSupportedVersion(
                OpenCodeServerInfo(version: "3.0.0", pid: nil, urls: nil, paths: nil)
            )
        )
        XCTAssertNoThrow(
            try OpenCodeLocator.requireSupportedVersion(
                OpenCodeServerInfo(version: "2.0.32", pid: nil, urls: nil, paths: nil)
            )
        )
    }
}
