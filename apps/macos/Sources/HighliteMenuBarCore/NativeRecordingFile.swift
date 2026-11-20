import Foundation

/// Small Foundation-only checks for the recorder's finalized movie file.
///
/// ScreenCaptureKit can stop delivering `recordingOutputDidFinishRecording`
/// after `stopCapture()` even though the MP4 is already finalized. The
/// recorder therefore treats the file on disk, not the notification, as the
/// source of truth. These helpers stay free of AVFoundation so the decision
/// can be tested without a window server or capture hardware.
public enum NativeRecordingFile {
    public static let movieFileName = "recording.mp4"

    /// ISO base media files normally carry an `ftyp` box at offset 4. This
    /// rejects empty and obviously incomplete files without reading the whole
    /// recording into memory. A match only means the header is present;
    /// AVFoundation remains the authority on whether the movie is playable.
    public static func looksLikeFinalizedMovie(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 12),
              header.count == 12
        else {
            return false
        }
        let bytes = [UInt8](header)
        return Array(bytes[4..<8]) == Array("ftyp".utf8)
    }
}
