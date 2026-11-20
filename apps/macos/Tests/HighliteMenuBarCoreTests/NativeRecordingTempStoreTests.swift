import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class NativeRecordingTempStoreTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("NativeRecordingTempStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? fileManager.removeItem(at: root)
        }
    }

    func testCleanupSweepsOnlyStalePrefixedDirectories() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-48 * 60 * 60)

        let stale = try makeDirectory("HighliteRecording-stale")
        try setModified(stale, to: old)
        let fresh = try makeDirectory("HighliteRecording-fresh")
        try setModified(fresh, to: now)
        let unrelated = try makeDirectory("SomethingElse-stale")
        try setModified(unrelated, to: old)
        let staleFile = root.appendingPathComponent("HighliteRecording-file")
        try Data("not a directory".utf8).write(to: staleFile)
        try setModified(staleFile, to: old)

        let target = try makeDirectory("target-dir")
        try setModified(target, to: old)
        let link = root.appendingPathComponent("HighliteRecording-link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let removed = NativeRecordingTempStore.cleanupStale(
            in: root,
            olderThan: 24 * 60 * 60,
            now: now,
            fileManager: fileManager
        )

        XCTAssertEqual(removed.map(\.lastPathComponent), ["HighliteRecording-stale"])
        XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
        XCTAssertTrue(fileManager.fileExists(atPath: staleFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: target.path))
    }

    func testZeroAgeLaunchSweepRemovesFreshPrefixedDirectories() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fresh = try makeDirectory("HighliteRecording-crashed")
        try setModified(fresh, to: now)

        let removed = NativeRecordingTempStore.cleanupStale(
            in: root,
            olderThan: 0,
            now: now,
            fileManager: fileManager
        )

        XCTAssertEqual(removed.map(\.lastPathComponent), ["HighliteRecording-crashed"])
        XCTAssertFalse(fileManager.fileExists(atPath: fresh.path))
    }

    func testRemoveRejectsPathsOutsideTheTemporaryWorkspace() throws {
        XCTAssertFalse(
            NativeRecordingTempStore.remove(
                URL(fileURLWithPath: "/highlite-should-not-exist", isDirectory: true)
            )
        )

        let recording = try makeDirectory("HighliteRecording-remove")
        XCTAssertTrue(NativeRecordingTempStore.remove(recording))
        XCTAssertFalse(fileManager.fileExists(atPath: recording.path))
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setModified(_ url: URL, to date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
