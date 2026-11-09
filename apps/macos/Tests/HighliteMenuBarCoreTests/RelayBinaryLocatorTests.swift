import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class RelayBinaryLocatorTests: XCTestCase {
    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data("#!/bin/sh\nexit 0\n".utf8)
            )
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlite-relay-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testConfiguredPathWins() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("custom-relay")
        try makeExecutable(at: binary)

        let located = RelayBinaryLocator.locate(
            configuredPath: binary.path,
            environment: [:],
            bundleURL: root,
            currentDirectory: root
        )
        XCTAssertEqual(located?.path, binary.path)
    }

    func testConfiguredMissingPathDoesNotFallBackToBundledBinary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Highlite.app", isDirectory: true)
        let bundled = bundle.appendingPathComponent("Contents/Resources/highlite-relay")
        try makeExecutable(at: bundled)
        let missing = root.appendingPathComponent("missing-relay").path

        let located = RelayBinaryLocator.locate(
            configuredPath: missing,
            environment: [:],
            bundleURL: bundle,
            currentDirectory: root
        )
        XCTAssertNil(located)
    }

    func testEnvironmentFallback() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("env-relay")
        try makeExecutable(at: binary)

        let located = RelayBinaryLocator.locate(
            configuredPath: nil,
            environment: ["HIGHLITE_RELAY_BIN": binary.path],
            bundleURL: root,
            currentDirectory: root
        )
        XCTAssertEqual(located?.path, binary.path)
    }

    func testBundledRelayIsFound() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Highlite.app", isDirectory: true)
        let binary = bundle.appendingPathComponent("Contents/Resources/highlite-relay")
        try makeExecutable(at: binary)

        let located = RelayBinaryLocator.locate(
            configuredPath: nil,
            environment: [:],
            bundleURL: bundle,
            currentDirectory: root
        )
        XCTAssertEqual(located?.path, binary.path)
    }

    func testDevelopmentBuildPathIsFound() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("target/release/highlite-relay")
        try makeExecutable(at: binary)

        let located = RelayBinaryLocator.locate(
            configuredPath: nil,
            environment: [:],
            bundleURL: root.appendingPathComponent("not-an-app"),
            currentDirectory: root
        )
        XCTAssertEqual(located?.path, binary.path)
    }

    func testCommandNameUsesAugmentedPATH() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("highlite-relay")
        try makeExecutable(at: binary)

        let located = RelayBinaryLocator.locate(
            configuredPath: "highlite-relay",
            environment: ["PATH": root.path, "HOME": root.path],
            bundleURL: root,
            currentDirectory: root
        )
        XCTAssertEqual(located?.path, binary.path)
    }

    func testMissingRelayReturnsNil() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let located = RelayBinaryLocator.locate(
            configuredPath: nil,
            environment: [:],
            bundleURL: root,
            currentDirectory: root
        )
        XCTAssertNil(located)
    }
}
