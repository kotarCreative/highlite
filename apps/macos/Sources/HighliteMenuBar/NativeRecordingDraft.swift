import AVFoundation
import AppKit
import Combine
import Foundation
import HighliteMenuBarCore

/// One reviewed moment inside a recording, extracted from the movie at a
/// specific timestamp. Annotations stay in normalized coordinates until the
/// canonical compiler renders the saved keyframe.
struct NativeRecordingMomentDraft: Identifiable {
    let id: UUID
    let atMs: Int
    let pngData: Data
    let image: NSImage
    var annotations: [NativeCaptureAnnotation]

    init(
        id: UUID = UUID(),
        atMs: Int,
        pngData: Data,
        image: NSImage,
        annotations: [NativeCaptureAnnotation] = []
    ) {
        self.id = id
        self.atMs = atMs
        self.pngData = pngData
        self.image = image
        self.annotations = annotations
    }
}

enum NativeRecordingDraftError: LocalizedError {
    case playheadTooEarly
    case playheadOutsideRecording
    case tooCloseToFrame(atMs: Int)
    case tooManyFrames(maximum: Int)
    case frameExtractionFailed(String)
    case frameEncodingFailed

    var errorDescription: String? {
        switch self {
        case .playheadTooEarly:
            return "Move the playhead past the opening half-second, or annotate the poster instead."
        case .playheadOutsideRecording:
            return "The playhead is outside this recording. Move it to a recorded moment."
        case .tooCloseToFrame(let atMs):
            return "There is already a frame at \(NativeRecordingDraft.timeText(atMs)). Move the playhead at least half a second away."
        case .tooManyFrames(let maximum):
            return "This recording already has the maximum of \(maximum) captured frames."
        case .frameExtractionFailed(let detail):
            return "The recording frame could not be read: \(detail)"
        case .frameEncodingFailed:
            return "The recording frame could not be encoded as a PNG."
        }
    }
}

/// Editable state for one finalized screen recording. The movie, poster, and
/// optional microphone audio remain untouched on disk; annotated moments are
/// extracted in memory and only read fully when the user explicitly saves.
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
    @Published var selectedTool: NativeCaptureAnnotationKind = .highlight
    @Published var posterAnnotations: [NativeCaptureAnnotation] = []
    @Published private(set) var moments: [NativeRecordingMomentDraft] = []
    /// `nil` selects the recording poster at 0 ms.
    @Published private(set) var selectedFrameID: UUID?
    @Published private(set) var playbackTimeMilliseconds = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isCapturingFrame = false

    private var discarded = false
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []

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

        installPlaybackObservers()
    }

    var hasMicrophoneAudio: Bool {
        output.audioURL != nil
    }

    var keyframeCount: Int {
        1 + moments.count
    }

    var canSave: Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= NativeRecordingBundleBuilder.maximumNoteLength
    }

    var canAddMoment: Bool {
        moments.count < NativeRecordingBundleBuilder.maximumMoments(
            forDurationMilliseconds: durationMilliseconds
        )
    }

    var isPosterSelected: Bool {
        selectedFrameID == nil
    }

    var selectedImage: NSImage {
        selectedMoment?.image ?? image
    }

    var selectedFrameLabel: String {
        selectedMoment.map { "Frame \(Self.timeText($0.atMs))" } ?? "Poster · 0:00"
    }

    var selectedAnnotations: [NativeCaptureAnnotation] {
        selectedMoment?.annotations ?? posterAnnotations
    }

    private var selectedMoment: NativeRecordingMomentDraft? {
        guard let selectedFrameID else { return nil }
        return moments.first { $0.id == selectedFrameID }
    }

    private var selectedMomentIndex: Int? {
        guard let selectedFrameID else { return nil }
        return moments.firstIndex { $0.id == selectedFrameID }
    }

    func selectPoster() {
        pause()
        seek(toMilliseconds: 0)
        selectedFrameID = nil
    }

    func selectMoment(id: UUID) {
        guard let moment = moments.first(where: { $0.id == id }) else { return }
        pause()
        seek(toMilliseconds: moment.atMs)
        selectedFrameID = id
    }

    func removeMoment(id: UUID) {
        guard let index = moments.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedFrameID == id
        moments.remove(at: index)
        if wasSelected {
            if let next = moments.first {
                selectMoment(id: next.id)
            } else {
                selectPoster()
            }
        }
    }

    @discardableResult
    func addAnnotation(_ annotation: NativeCaptureAnnotation) -> Bool {
        guard annotation.isRenderable(imageWidth: imageWidth, imageHeight: imageHeight),
              selectedAnnotations.count < NativeCaptureAnnotationLimits.maximumAnnotations
        else {
            return false
        }
        if let index = selectedMomentIndex {
            var moment = moments[index]
            moment.annotations.append(annotation)
            moments[index] = moment
        } else {
            posterAnnotations.append(annotation)
        }
        return true
    }

    func undoLastAnnotation() {
        if let index = selectedMomentIndex {
            guard !moments[index].annotations.isEmpty else { return }
            var moment = moments[index]
            moment.annotations.removeLast()
            moments[index] = moment
        } else {
            guard !posterAnnotations.isEmpty else { return }
            posterAnnotations.removeLast()
        }
    }

    func clearAnnotations() {
        if let index = selectedMomentIndex {
            var moment = moments[index]
            moment.annotations.removeAll()
            moments[index] = moment
        } else {
            posterAnnotations.removeAll()
        }
    }

    func togglePlayback() {
        if player.rate == 0 {
            if playbackTimeMilliseconds >= durationMilliseconds - 100 {
                seek(toMilliseconds: 0)
            }
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(toMilliseconds milliseconds: Int) {
        let clamped = max(0, min(durationMilliseconds, milliseconds))
        playbackTimeMilliseconds = clamped
        let time = CMTime(value: CMTimeValue(clamped), timescale: 1_000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Pauses playback, extracts the current video frame, and selects it for
    /// annotation. Frames are captured at least half a second apart so the
    /// compiler's duplicate-frame rule cannot merge them.
    func captureFrameForAnnotation() async throws {
        guard !discarded else { return }
        guard !isCapturingFrame else { return }
        guard canAddMoment else {
            throw NativeRecordingDraftError.tooManyFrames(
                maximum: NativeRecordingBundleBuilder.maximumMoments(
                    forDurationMilliseconds: durationMilliseconds
                )
            )
        }

        player.pause()
        isPlaying = false
        let time = player.currentTime()
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else {
            throw NativeRecordingDraftError.playheadOutsideRecording
        }
        let requestedAtMs = Int((seconds * 1_000).rounded())
        guard requestedAtMs >= NativeRecordingBundleBuilder.minimumMomentGapMilliseconds else {
            throw NativeRecordingDraftError.playheadTooEarly
        }
        guard requestedAtMs <= durationMilliseconds else {
            throw NativeRecordingDraftError.playheadOutsideRecording
        }
        try ensureGap(from: requestedAtMs)

        isCapturingFrame = true
        defer { isCapturingFrame = false }

        do {
            let asset = AVURLAsset(url: output.movieURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Match the recorder's poster budget so every frame shares the
            // manifest viewport dimensions even when the source video is 4K.
            generator.maximumSize = CGSize(width: imageWidth, height: imageHeight)
            let tolerance = CMTime(value: 1, timescale: 60)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let (frame, actualTime) = try await generator.image(at: time)
            guard !discarded else { return }
            let actualSeconds = CMTimeGetSeconds(actualTime)
            let actualAtMs = actualSeconds.isFinite
                ? Int((actualSeconds * 1_000).rounded())
                : requestedAtMs
            let atMs = max(
                NativeRecordingBundleBuilder.minimumMomentGapMilliseconds,
                min(durationMilliseconds, actualAtMs)
            )
            try ensureGap(from: atMs)
            guard let pngData = Self.pngData(from: frame),
                  let nsImage = NSImage(data: pngData)
            else {
                throw NativeRecordingDraftError.frameEncodingFailed
            }
            let moment = NativeRecordingMomentDraft(
                atMs: atMs,
                pngData: pngData,
                image: nsImage
            )
            moments.append(moment)
            moments.sort { $0.atMs < $1.atMs }
            selectedFrameID = moment.id
            playbackTimeMilliseconds = atMs
        } catch let error as NativeRecordingDraftError {
            throw error
        } catch {
            throw NativeRecordingDraftError.frameExtractionFailed(error.localizedDescription)
        }
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
        let bundleMoments = moments.map { moment in
            NativeRecordingMoment(
                atMs: moment.atMs,
                pngData: moment.pngData,
                annotations: moment.annotations
            )
        }
        return try NativeRecordingBundleBuilder.build(
            movieData: movieData,
            posterPNGData: posterData,
            audioData: audioData,
            audioFileExtension: audioExtension,
            note: note,
            annotations: posterAnnotations,
            moments: bundleMoments,
            durationMilliseconds: durationMilliseconds
        )
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Stops playback, removes observers, and deletes the recorder's temporary
    /// working directory. The relay receives the archive bytes, never this
    /// directory.
    func discard() {
        guard !discarded else { return }
        discarded = true
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        cancellables.removeAll()
        player.replaceCurrentItem(with: nil)
        NativeRecordingTempStore.remove(output.directory)
    }

    nonisolated static func timeText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func ensureGap(from atMs: Int) throws {
        if let nearby = moments.min(by: {
            abs($0.atMs - atMs) < abs($1.atMs - atMs)
        }), abs(nearby.atMs - atMs) < NativeRecordingBundleBuilder.minimumMomentGapMilliseconds {
            throw NativeRecordingDraftError.tooCloseToFrame(atMs: nearby.atMs)
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func installPlaybackObservers() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            // The observer queue is the main queue, so this runs on the main
            // actor's executor. Assume that isolation instead of spawning a
            // task per tick: out-of-order tasks could update the clock after
            // the draft was discarded, and they outlive the window teardown.
            MainActor.assumeIsolated {
                self?.updatePlaybackClock(time)
            }
        }

        NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.discarded else { return }
                    self.isPlaying = false
                    self.playbackTimeMilliseconds = self.durationMilliseconds
                }
            }
            .store(in: &cancellables)
    }

    private func updatePlaybackClock(_ time: CMTime) {
        guard !discarded else { return }
        let seconds = CMTimeGetSeconds(time)
        if seconds.isFinite {
            playbackTimeMilliseconds = max(
                0,
                min(durationMilliseconds, Int((seconds * 1_000).rounded()))
            )
        }
        if player.rate == 0 {
            isPlaying = false
        }
    }
}
