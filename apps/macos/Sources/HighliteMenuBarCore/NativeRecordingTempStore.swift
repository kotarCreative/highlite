import Foundation

/// Lifecycle helpers for the recorder's private temporary directories.
///
/// A finalized recording can be large, so the app removes its working copy as
/// soon as the review window is dismissed. A crash or forced quit can leave a
/// directory behind; launch-time cleanup passes an age of zero because the app
/// treats launch as its single-instance boundary. Only directories carrying
/// this app's prefix are touched, so unrelated apps are never affected.
public enum NativeRecordingTempStore {
    public static let directoryPrefix = "HighliteRecording-"
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    /// Removes stale recorder directories directly under `root`.
    ///
    /// Symlinks are skipped rather than followed. Returns the removed URLs in
    /// sorted order so callers and tests can report what was cleaned up.
    @discardableResult
    public static func cleanupStale(
        in root: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = staleAfter,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [URL] {
        guard age >= 0 else { return [] }
        let cutoff = now.addingTimeInterval(-age)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var removed: [URL] = []
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix(directoryPrefix),
                  let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified <= cutoff
            else {
                continue
            }
            do {
                try fileManager.removeItem(at: entry)
                removed.append(entry)
            } catch {
                continue
            }
        }
        return removed.sorted { $0.path < $1.path }
    }

    /// Removes one finalized recording directory. The path is constrained to
    /// the system temp directory or an app-prefixed directory so a malformed
    /// recorder result cannot delete arbitrary user data.
    @discardableResult
    public static func remove(
        _ directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let standardized = directory.standardizedFileURL
        guard isSafeLocation(standardized) else { return false }
        return (try? fileManager.removeItem(at: standardized)) != nil
    }

    private static func isSafeLocation(_ url: URL) -> Bool {
        let path = url.path
        guard path != "/", !path.isEmpty else { return false }
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if path == temp || path.hasPrefix(temp + "/") {
            return true
        }
        return url.lastPathComponent.hasPrefix(directoryPrefix)
    }
}
