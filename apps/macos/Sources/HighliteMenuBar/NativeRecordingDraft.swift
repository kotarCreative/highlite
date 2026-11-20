import AVFoundation
import AppKit
import Combine
import Foundation
import HighliteMenuBarCore

/// Editable state for one finalized screen recording. The movie, poster, and
/// optional microphone audio remain untouched on disk; the review window reads
/// them only when the user explicitly saves.
@MainActor
final class NativeRecordingDraft: ObservableObject {
    let output: NativeRecordingOutput
    let posterData: Data
    let image: NSImage
    let imageWidth: Int
    let imageHeight: Int
    let durationMilliseconds: Int
    let warnings: [String]
    let player: AVPlayer

    @Published var note = ""
    @Published var highlight: NativeCaptureRect?

    private var discarded = false

    init(output: NativeRecordingOutput) throws {
        guard FileManager.default.fileExists(atPath: output.movieURL.path) else {
            throw NativeRecordingBundleError.invalidMovie
        }
        guard output.durationMilliseconds > 0,
              output.durationMilliseconds <= NativeRecordingBundleBuilder.maximumDurationMilliseconds
        else {
            throw NativeRecordingBundleError.invalidDuration
        }
        guard let posterData = try? Data(contentsOf: output.posterPNGURL),
              !posterData.isEmpty,
              let image = NSImage(data: posterData)
        else {
            throw NativeRecordingBundleError.invalidPoster
        }
        let (width, height) = try NativeCaptureBundleBuilder.imageDimensions(in: posterData)

        self.output = output
        self.posterData = posterData
        self.image = image
        self.imageWidth = width
        self.imageHeight = height
        self.durationMilliseconds = output.durationMilliseconds
        self.warnings = output.warnings
        self.player = AVPlayer(url: output.movieURL)
    }

    var hasMicrophoneAudio: Bool {
        output.audioURL != nil
    }

    var canSave: Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= NativeRecordingBundleBuilder.maximumNoteLength
    }

    func makeBundle() throws -> NativeRecordingBundle {
        guard let movieData = try? Data(contentsOf: output.movieURL, options: .mappedIfSafe),
              !movieData.isEmpty
        else {
            throw NativeRecordingBundleError.invalidMovie
        }
        let audioData = try output.audioURL.map { url in
            try Data(contentsOf: url, options: .mappedIfSafe)
        }
        let audioExtension: String
        if let value = output.audioURL?.pathExtension.lowercased(), !value.isEmpty {
            audioExtension = value
        } else {
            audioExtension = "m4a"
        }
        return try NativeRecordingBundleBuilder.build(
            movieData: movieData,
            posterPNGData: posterData,
            audioData: audioData,
            audioFileExtension: audioExtension,
            note: note,
            highlight: highlight,
            durationMilliseconds: durationMilliseconds
        )
    }

    func pause() {
        player.pause()
    }

    /// Stops playback and deletes the recorder's temporary working directory.
    /// The relay receives the archive bytes, never this directory.
    func discard() {
        guard !discarded else { return }
        discarded = true
        player.pause()
        player.replaceCurrentItem(with: nil)
        NativeRecordingTempStore.remove(output.directory)
    }
}
