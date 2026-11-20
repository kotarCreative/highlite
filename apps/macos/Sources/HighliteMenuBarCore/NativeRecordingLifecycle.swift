import Foundation

/// Tracks whether a movie file that is still being written has stopped growing.
///
/// The recorder polls the MP4 after `stopCapture()` because ScreenCaptureKit
/// does not reliably deliver `recordingOutputDidFinishRecording` on every
/// macOS release. A size is only stable after two consecutive observations
/// with the same positive value; a missing or empty file resets the sample so
/// a briefly truncated file cannot look final.
public struct NativeRecordingFileStability {
    private var lastObservedSize: Int64?

    public init() {}

    /// Records one observation and returns `true` when the size is positive
    /// and unchanged from the previous observation.
    @discardableResult
    public mutating func observe(fileSize: Int64) -> Bool {
        guard fileSize > 0 else {
            lastObservedSize = nil
            return false
        }
        defer { lastObservedSize = fileSize }
        return lastObservedSize == fileSize
    }

    public mutating func reset() {
        lastObservedSize = nil
    }
}

/// Ensures one capture stream is asked to stop at most once.
///
/// Calling `SCStream.stopCapture()` a second time after a stop is already in
/// flight (for example from failure or cancellation teardown) is a suspected
/// ScreenCaptureKit crash path. The gate is reset only when a new capture
/// session starts.
public struct NativeRecordingStopGate {
    private var requested = false

    public init() {}

    public var hasRequestedStop: Bool {
        requested
    }

    /// Returns `true` exactly once so the caller can perform the stop. A
    /// stream that the system already stopped never needs a stop request.
    public mutating func beginStop(streamAlreadyStopped: Bool) -> Bool {
        guard !streamAlreadyStopped, !requested else {
            return false
        }
        requested = true
        return true
    }

    public mutating func reset() {
        requested = false
    }
}
