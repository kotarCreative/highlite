import Foundation
import HighliteMenuBarCore

/// Runs the system's interactive still-capture UI and returns PNG bytes after
/// deleting the temporary file. It never takes a screenshot without the user
/// completing the macOS selection flow.
struct NativeCaptureService {
    func captureInteractive() async throws -> Data {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capture.png")
        let status = try await runCapture(output: output)

        let exists = FileManager.default.fileExists(atPath: output.path)
        guard exists else {
            throw NativeCaptureCommandError.cancelled
        }
        guard status == 0 else {
            throw NativeCaptureCommandError.failed(status)
        }
        guard let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw NativeCaptureCommandError.empty
        }
        return data
    }

    private func runCapture(output: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(
                    fileURLWithPath: NativeCaptureCommand.executablePath
                )
                process.arguments = NativeCaptureCommand.arguments(outputPath: output.path)
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(throwing: NativeCaptureCommandError.unavailable)
                }
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HighliteCapture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
