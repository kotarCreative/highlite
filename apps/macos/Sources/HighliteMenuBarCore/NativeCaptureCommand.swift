import Foundation

/// The explicit macOS still-capture command. `screencapture -i` shows the
/// system selection UI, where the user can drag a region or press Space to pick
/// a window. `-x` suppresses the shutter sound; `-t png` keeps the archive
/// self-contained. No global monitoring or focused-window APIs are involved.
public enum NativeCaptureCommand {
    public static let executablePath = "/usr/sbin/screencapture"

    public static func arguments(outputPath: String) -> [String] {
        ["-i", "-x", "-t", "png", outputPath]
    }
}

public enum NativeCaptureCommandError: LocalizedError, Equatable {
    case unavailable
    case cancelled
    case empty
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The macOS screen capture tool is unavailable."
        case .cancelled:
            return "No screenshot was created. If no selection appeared, allow Screen Recording for Highlite in System Settings, then try again."
        case .empty:
            return "The screen capture was empty."
        case .failed(let status):
            return "The macOS screen capture tool failed with status \(status)."
        }
    }
}
