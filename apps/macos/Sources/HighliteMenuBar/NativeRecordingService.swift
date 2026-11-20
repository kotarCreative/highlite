import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import HighliteMenuBarCore
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Runtime availability for the native screen recording engine.
///
/// The service itself is macOS 15+, because `SCRecordingOutput` is the only
/// part of ScreenCaptureKit that finalizes a movie for us. The rest of the app
/// can check this value on macOS 14 without referencing the macOS 15 types.
public enum NativeRecordingAvailability {
    public static var isSupported: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }
}

/// Bounded recording policy. The movie has no configurable bitrate through
/// `SCRecordingOutput`, so the service also caps the capture dimensions and
/// polls the recorder's reported file size. The automatic thresholds leave
/// headroom for the encoder to flush before the hard limits are checked.
public enum NativeRecordingLimits {
    /// Longest movie Highlite promises to return.
    public static let maximumDurationSeconds: TimeInterval = 45
    /// Stop capture slightly before the promise so finalization stays below it.
    public static let automaticStopDurationSeconds: TimeInterval = 44.5
    /// Largest movie Highlite promises to return.
    public static let maximumMovieBytes: Int64 = 48 * 1_024 * 1_024
    /// Stop capture before the hard limit so the muxer can finish writing.
    public static let automaticStopBytes: Int64 = 46 * 1_024 * 1_024
    /// Longest edge of the captured video. This keeps H.264 bitrate plausible
    /// for the 45 second / 48 MiB budget on large Retina displays.
    public static let maximumVideoLongEdgePixels = 1_920
    public static let videoFrameRate: Int32 = 30
    public static let progressIntervalSeconds: TimeInterval = 0.5
    /// How long to wait for `recordingOutputDidStartRecording`.
    public static let startTimeoutSeconds: TimeInterval = 8
    /// How long to wait for the finalized movie to become readable after stop.
    public static let finishTimeoutSeconds: TimeInterval = 15
    /// How often to probe the finalized movie when the finish notification is
    /// late or never arrives.
    public static let finalizationPollIntervalSeconds: TimeInterval = 0.1
    /// How long cancel waits for the muxer to release its file.
    public static let cancellationDrainTimeoutSeconds: TimeInterval = 5
}

public enum NativeRecordingError: LocalizedError, Equatable {
    case cancelled
    case unsupportedOperatingSystem
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case microphoneUnavailable
    case contentSelectionFailed(String)
    case captureStartFailed(String)
    case recordingDidNotStart
    case recordingFailed(String)
    case recordingStopped(String)
    case stopFailed(String)
    case recordingFileMissing
    case recordingFileEmpty
    case movieTooLarge(actualBytes: Int64)
    case finishTimedOut
    case posterExtractionFailed(String)
    case temporaryDirectoryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Screen recording was cancelled."
        case .unsupportedOperatingSystem:
            return "Screen recording requires macOS 15 or newer."
        case .alreadyRecording:
            return "A screen recording is already in progress."
        case .notRecording:
            return "No screen recording is in progress."
        case .microphonePermissionDenied:
            return "Highlite does not have microphone access. Allow it in System Settings > Privacy & Security > Microphone, then try again."
        case .microphoneUnavailable:
            return "No microphone is available for narration."
        case .contentSelectionFailed(let detail):
            return "The screen and window picker failed: \(detail)"
        case .captureStartFailed(let detail):
            return "Screen recording could not start: \(detail)"
        case .recordingDidNotStart:
            return "Screen recording did not start."
        case .recordingFailed(let detail):
            return "Screen recording failed: \(detail)"
        case .recordingStopped(let detail):
            return "Screen recording stopped: \(detail)"
        case .stopFailed(let detail):
            return "Screen recording could not be stopped cleanly: \(detail)"
        case .recordingFileMissing:
            return "The recorded movie file was not created."
        case .recordingFileEmpty:
            return "The recorded movie file is empty."
        case .movieTooLarge(let actualBytes):
            return "The recorded movie is too large (\(actualBytes) bytes; limit is \(NativeRecordingLimits.maximumMovieBytes) bytes)."
        case .finishTimedOut:
            return "The screen recorder did not finish writing the movie in time."
        case .posterExtractionFailed(let detail):
            return "A preview image could not be created from the movie: \(detail)"
        case .temporaryDirectoryFailed(let detail):
            return "A private recording directory could not be created: \(detail)"
        }
    }
}

public enum NativeRecordingStopReason: String, Sendable {
    case userRequested
    case maximumDurationReached
    case maximumFileSizeReached
    case screenCaptureStopped
    case recordingFinishedUnexpectedly
}

public struct NativeRecordingProgress: Sendable, Equatable {
    public let elapsedSeconds: TimeInterval
    public let recordedBytes: Int64
    public let durationLimitFraction: Double
    public let sizeLimitFraction: Double

    public static let zero = NativeRecordingProgress(
        elapsedSeconds: 0,
        recordedBytes: 0,
        durationLimitFraction: 0,
        sizeLimitFraction: 0
    )

    public init(
        elapsedSeconds: TimeInterval,
        recordedBytes: Int64,
        durationLimitFraction: Double,
        sizeLimitFraction: Double
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.recordedBytes = recordedBytes
        self.durationLimitFraction = durationLimitFraction
        self.sizeLimitFraction = sizeLimitFraction
    }
}

/// A completed recording. The service never deletes a successful result; the
/// caller owns `directoryURL` and must consume or discard it.
public struct NativeRecordingResult: Sendable {
    /// Private (mode 0700) directory containing every artifact below.
    public let directoryURL: URL
    /// H.264 MP4 written by `SCRecordingOutput`. This URL is only published
    /// after the movie on disk is readable by AVFoundation.
    public let movieURL: URL
    /// Separate AAC/M4A narration track extracted from the movie when present.
    public let audioURL: URL?
    /// PNG preview frame extracted from the movie, when extraction succeeds.
    public let posterURL: URL?
    public let durationMilliseconds: Int
    public let movieFileSizeBytes: Int64
    public let microphoneRequested: Bool
    public let containsMicrophoneAudio: Bool
    public let createdAt: Date
    /// Non-fatal post-processing or capture notes. The movie is still usable.
    public let warnings: [String]

    /// Deletes every artifact. This is idempotent and is the caller's explicit
    /// cleanup point for a successful recording.
    public func discard() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@available(macOS 15.0, *)
@MainActor
public protocol NativeRecordingServiceDelegate: AnyObject {
    func recordingServiceDidStart(_ service: NativeRecordingService)
    func recordingService(
        _ service: NativeRecordingService,
        didUpdate progress: NativeRecordingProgress
    )
    func recordingService(
        _ service: NativeRecordingService,
        didStopAutomatically reason: NativeRecordingStopReason
    )
    func recordingService(
        _ service: NativeRecordingService,
        didFinishWith result: NativeRecordingResult
    )
    func recordingService(_ service: NativeRecordingService, didFailWith error: Error)
    func recordingServiceDidCancel(_ service: NativeRecordingService)
}

@available(macOS 15.0, *)
public extension NativeRecordingServiceDelegate {
    func recordingServiceDidStart(_ service: NativeRecordingService) {}
    func recordingService(
        _ service: NativeRecordingService,
        didUpdate progress: NativeRecordingProgress
    ) {}
    func recordingService(
        _ service: NativeRecordingService,
        didStopAutomatically reason: NativeRecordingStopReason
    ) {}
    func recordingService(
        _ service: NativeRecordingService,
        didFinishWith result: NativeRecordingResult
    ) {}
    func recordingService(_ service: NativeRecordingService, didFailWith error: Error) {}
    func recordingServiceDidCancel(_ service: NativeRecordingService) {}
}

/// Records the screen or a single window that the user selects in the system
/// content-sharing picker. Video and optional microphone narration are written
/// as one H.264 MP4 by `SCRecordingOutput`; system/app audio is always off.
///
/// Lifecycle:
/// 1. `start(includeMicrophone:)` presents the picker and returns after capture
///    has actually started.
/// 2. Progress arrives through `progress` or the delegate.
/// 3. `stop()` finalizes the movie and returns artifacts once the file on disk
///    is stable and readable; the finish callback is not required.
/// 4. `cancel()` tears down capture and deletes the private temporary directory.
///
/// The service has no global event monitors. It only registers a picker
/// observer while the picker is visible, and only polls its own recorder while
/// capture is running. The caller should invoke `cancel()` from application
/// termination if it wants immediate cleanup.
@available(macOS 15.0, *)
@MainActor
public final class NativeRecordingService: NSObject, ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case choosingContent
        case preparing
        case recording
        case stopping
        case cancelling
        case finished
        case failed
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var progress: NativeRecordingProgress = .zero
    @Published public private(set) var lastResult: NativeRecordingResult?
    public private(set) var lastError: NativeRecordingError?
    public private(set) var microphoneRequested = false

    /// Held weakly so an app model can own the service and be its delegate
    /// without creating a retain cycle. Callbacks are delivered on the main
    /// actor and are not dropped while the service is alive.
    public weak var delegate: (any NativeRecordingServiceDelegate)?

    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var workingDirectory: URL?
    private var finalizationTask: Task<NativeRecordingResult, Error>?

    private var pickerContinuation: CheckedContinuation<SCContentFilter, Error>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    private var recordingStarted = false
    private var recordingDidFinish = false
    private var recordingFailure: Error?
    private var streamStoppedBySystem = false
    private var recordingStartDate: Date?
    private var sessionCreatedAt = Date()
    private var failureNotified = false
    private var isTearingDown = false

    public override init() {
        super.init()
    }

    // MARK: - Public lifecycle

    /// Presents the explicit macOS content picker and begins recording after
    /// the user chooses a display or window. Throws `NativeRecordingError.cancelled`
    /// when the user cancels the picker.
    public func start(includeMicrophone: Bool) async throws {
        guard NativeRecordingAvailability.isSupported else {
            throw NativeRecordingError.unsupportedOperatingSystem
        }
        guard state != .choosingContent,
              state != .preparing,
              state != .recording,
              state != .stopping,
              state != .cancelling
        else {
            throw NativeRecordingError.alreadyRecording
        }

        resetForNewSession()
        microphoneRequested = includeMicrophone
        sessionCreatedAt = Date()
        state = .preparing

        do {
            try ensureStartIsCurrent()
            if includeMicrophone {
                try await ensureMicrophoneAccess()
                try ensureStartIsCurrent()
            }

            let directory = try makePrivateTemporaryDirectory()
            workingDirectory = directory
            state = .choosingContent

            let filter = try await selectContent()
            try ensureStartIsCurrent()

            state = .preparing
            try await beginCapture(filter: filter, includeMicrophone: includeMicrophone)
            try ensureStartIsCurrent()
            try await waitForRecordingStart()
            try ensureStartIsCurrent()
        } catch {
            let recordingError = normalizeStartError(error)
            if recordingError == .cancelled {
                await cancelSessionSilently()
            } else {
                await failSession(recordingError)
            }
            throw recordingError
        }
    }

    /// Stops capture. The returned movie is only available after the finalized
    /// MP4 on disk is stable and readable by AVFoundation.
    public func stop() async throws -> NativeRecordingResult {
        if state == .finished, let lastResult {
            return lastResult
        }
        if let finalizationTask = finalizationTask {
            return try await finalizationTask.value
        }

        switch state {
        case .recording:
            let task = beginFinalization(reason: .userRequested)
            return try await task.value
        case .choosingContent:
            cancelPickerSelection()
            throw NativeRecordingError.notRecording
        case .failed:
            throw lastError ?? NativeRecordingError.notRecording
        default:
            throw NativeRecordingError.notRecording
        }
    }

    /// Tears down any picker/capture and deletes the private workspace. If a
    /// movie was already finalized, cancel waits for that work and then removes
    /// its result directory. The delegate receives `recordingServiceDidCancel`
    /// only when an active session was actually cancelled.
    public func cancel() async {
        guard !isTearingDown else {
            return
        }
        let hadActiveSession = state == .choosingContent
            || state == .preparing
            || state == .recording
            || state == .stopping

        if state == .finished {
            return
        }

        isTearingDown = true
        defer { isTearingDown = false }

        cancelPickerSelection()
        state = .cancelling
        stopTimers()
        if let startContinuation = startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: CancellationError())
        }
        if let finishContinuation = finishContinuation {
            self.finishContinuation = nil
            finishContinuation.resume(throwing: CancellationError())
        }

        if let finalizationTask = finalizationTask {
            // Let the encoder close cleanly, then discard the finalized work.
            do {
                let result = try await finalizationTask.value
                result.discard()
            } catch {
                // The failure path already removed the workspace.
            }
        } else {
            let needsDrain = recordingStarted && (stream != nil || recordingOutput != nil)
            await stopStreamForCleanup()
            if needsDrain && !recordingDidFinish {
                _ = try? await waitForRecordingFinish(
                    timeout: NativeRecordingLimits.cancellationDrainTimeoutSeconds
                )
            }
            releaseCaptureObjects()
            cleanupWorkingDirectory()
        }

        stream = nil
        recordingOutput = nil
        state = .idle
        progress = .zero
        lastResult = nil
        lastError = nil
        if hadActiveSession {
            delegate?.recordingServiceDidCancel(self)
        }
    }

    // MARK: - Start

    private func ensureStartIsCurrent() throws {
        try Task.checkCancellation()
        guard state != .idle, state != .cancelling, state != .failed else {
            throw NativeRecordingError.cancelled
        }
    }

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw NativeRecordingError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw NativeRecordingError.microphonePermissionDenied
        @unknown default:
            throw NativeRecordingError.microphonePermissionDenied
        }
    }

    private func selectContent() async throws -> SCContentFilter {
        var pickerConfiguration = SCContentSharingPickerConfiguration()
        pickerConfiguration.allowedPickerModes = [.singleDisplay, .singleWindow]
        pickerConfiguration.allowsChangingSelectedContent = false
        picker.configuration = pickerConfiguration
        picker.isActive = true

        defer {
            picker.isActive = false
            picker.remove(self)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pickerContinuation = continuation

                if Task.isCancelled {
                    self.pickerContinuation = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }

                picker.add(self)
                picker.present()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPickerSelection()
            }
        }
    }

    private func beginCapture(
        filter: SCContentFilter,
        includeMicrophone: Bool
    ) async throws {
        guard let directory = workingDirectory else {
            throw NativeRecordingError.temporaryDirectoryFailed("No workspace is available.")
        }

        let dimensions = videoDimensions(for: filter)
        var configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: NativeRecordingLimits.videoFrameRate
        )
        configuration.queueDepth = 5
        configuration.showsCursor = true
        // Explicitly exclude system and app audio. Narration is the only audio
        // input this service enables.
        configuration.capturesAudio = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1

        if includeMicrophone {
            guard let microphone = AVCaptureDevice.default(for: .audio) else {
                throw NativeRecordingError.microphoneUnavailable
            }
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = microphone.uniqueID
        } else {
            configuration.captureMicrophone = false
        }

        let movieURL = directory.appendingPathComponent(
            NativeRecordingFile.movieFileName,
            isDirectory: false
        )
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = movieURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264

        let recordingOutput = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: self
        )
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        // Publish the objects before starting capture: SCK can deliver its
        // start/failure callbacks while `startCapture()` is still suspended.
        self.recordingOutput = recordingOutput
        self.stream = stream

        do {
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()
        } catch {
            self.stream = nil
            self.recordingOutput = nil
            throw NativeRecordingError.captureStartFailed(error.localizedDescription)
        }
    }

    private func waitForRecordingStart() async throws {
        if recordingStarted {
            return
        }
        if let recordingFailure = recordingFailure {
            throw NativeRecordingError.recordingFailed(recordingFailure.localizedDescription)
        }
        guard state == .preparing else {
            throw NativeRecordingError.recordingDidNotStart
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.startContinuation = continuation

                if Task.isCancelled {
                    self.startContinuation = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.startTimeoutTask?.cancel()
                self.startTimeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            nanoseconds: UInt64(
                                NativeRecordingLimits.startTimeoutSeconds * 1_000_000_000
                            )
                        )
                    } catch {
                        return
                    }
                    self?.handleStartTimeout()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.handleStartCancellation()
            }
        }
    }

    private func videoDimensions(for filter: SCContentFilter) -> (width: Int, height: Int) {
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let content = filter.contentRect
        let rawWidth = max(content.width * scale, 2)
        let rawHeight = max(content.height * scale, 2)
        let longestEdge = max(rawWidth, rawHeight)
        let reduction = min(
            1,
            CGFloat(NativeRecordingLimits.maximumVideoLongEdgePixels) / longestEdge
        )

        func evenDimension(_ value: CGFloat) -> Int {
            let rounded = max(2, Int((value * reduction).rounded(.down)))
            return rounded - (rounded % 2)
        }

        return (evenDimension(rawWidth), evenDimension(rawHeight))
    }

    // MARK: - Finalization

    private func beginFinalization(
        reason: NativeRecordingStopReason
    ) -> Task<NativeRecordingResult, Error> {
        if let finalizationTask = finalizationTask {
            return finalizationTask
        }

        state = .stopping
        monitorTask?.cancel()
        monitorTask = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil

        if reason != .userRequested {
            delegate?.recordingService(self, didStopAutomatically: reason)
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                throw NativeRecordingError.cancelled
            }
            do {
                return try await self.performFinalization(reason: reason)
            } catch {
                let error = self.normalizeFinalizationError(error)
                await self.failSession(error)
                throw error
            }
        }
        finalizationTask = task
        return task
    }

    private func performFinalization(
        reason: NativeRecordingStopReason
    ) async throws -> NativeRecordingResult {
        guard let directory = workingDirectory else {
            throw NativeRecordingError.temporaryDirectoryFailed("No workspace is available.")
        }

        let movieURL = directory.appendingPathComponent(
            NativeRecordingFile.movieFileName,
            isDirectory: false
        )
        let reportedDuration = recordingOutput
            .map { CMTimeGetSeconds($0.recordedDuration) } ?? 0

        var stopFailureDescription: String?
        if streamStoppedBySystem {
            // The stream already stopped on its own. Ask the recorder to
            // release the file handle, but treat that as best effort: the
            // movie on disk is the source of truth.
            if !recordingDidFinish,
               let stream = stream,
               let recordingOutput = recordingOutput {
                try? stream.removeRecordingOutput(recordingOutput)
            }
        } else if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                // The stream can already be torn down even when no system
                // stop was observed. Do not surface the framework error here;
                // it may be malformed, and the file is authoritative.
                stopFailureDescription = "The capture stream did not stop cleanly."
            }
        }

        // Detach the capture objects before touching the file. A second
        // `stopCapture()` from failure teardown is a suspected crash path
        // inside ScreenCaptureKit when the finish notification is late.
        stream = nil
        recordingOutput = nil
        monitorTask?.cancel()
        monitorTask = nil

        // `stopCapture()` asks the recorder to finish. The MP4 is normally
        // written by the time it returns, but the
        // `recordingOutputDidFinishRecording` notification may be delayed or
        // absent. Wait for a stable, finalized file instead of blocking on
        // that callback.
        let asset = try await waitForFinalizedMovie(at: movieURL)

        let fileSize = try movieFileSize(at: movieURL)
        guard fileSize < NativeRecordingLimits.maximumMovieBytes else {
            throw NativeRecordingError.movieTooLarge(actualBytes: fileSize)
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let wallSeconds = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let effectiveDuration: TimeInterval
        if durationSeconds.isFinite && durationSeconds > 0 {
            effectiveDuration = durationSeconds
        } else if reportedDuration.isFinite && reportedDuration > 0 {
            effectiveDuration = reportedDuration
        } else {
            effectiveDuration = wallSeconds.isFinite ? wallSeconds : 0
        }
        let durationMilliseconds = max(1, Int((effectiveDuration * 1_000).rounded()))

        var warnings: [String] = []
        if effectiveDuration > NativeRecordingLimits.maximumDurationSeconds + 0.75 {
            warnings.append(
                "The movie is longer than the intended \(Int(NativeRecordingLimits.maximumDurationSeconds)) seconds."
            )
        }
        if let stopFailureDescription = stopFailureDescription {
            warnings.append("Capture stop reported: \(stopFailureDescription)")
        } else if let pendingStopWarning = pendingStopWarning {
            warnings.append("Screen capture stopped: \(pendingStopWarning)")
        } else if streamStoppedBySystem {
            warnings.append("Screen capture was stopped by macOS or the user.")
        }
        if reason == .recordingFinishedUnexpectedly {
            warnings.append("Screen capture ended before Highlite requested a stop.")
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty
        var audioURL: URL?
        if hasAudio {
            let candidate = directory.appendingPathComponent("audio.m4a", isDirectory: false)
            do {
                try await exportAudio(from: asset, to: candidate)
                audioURL = candidate
            } catch {
                warnings.append("Separate narration audio could not be extracted: \(error.localizedDescription)")
            }
        } else if microphoneRequested {
            warnings.append("Microphone narration was requested, but the movie has no audio track.")
        }

        var posterURL: URL?
        let posterCandidate = directory.appendingPathComponent("poster.png", isDirectory: false)
        do {
            try await writePoster(
                from: asset,
                duration: duration,
                fallbackDurationSeconds: effectiveDuration,
                to: posterCandidate
            )
            posterURL = posterCandidate
        } catch {
            warnings.append("Preview image could not be created: \(error.localizedDescription)")
        }

        restrictDirectoryContents(directory)

        let result = NativeRecordingResult(
            directoryURL: directory,
            movieURL: movieURL,
            audioURL: audioURL,
            posterURL: posterURL,
            durationMilliseconds: durationMilliseconds,
            movieFileSizeBytes: fileSize,
            microphoneRequested: microphoneRequested,
            containsMicrophoneAudio: hasAudio,
            createdAt: sessionCreatedAt,
            warnings: warnings
        )

        workingDirectory = nil
        lastResult = result
        lastError = nil
        progress = NativeRecordingProgress(
            elapsedSeconds: effectiveDuration,
            recordedBytes: fileSize,
            durationLimitFraction: min(
                effectiveDuration / NativeRecordingLimits.maximumDurationSeconds,
                1
            ),
            sizeLimitFraction: min(
                Double(fileSize) / Double(NativeRecordingLimits.maximumMovieBytes),
                1
            )
        )
        state = .finished
        delegate?.recordingService(self, didFinishWith: result)
        return result
    }

    private func waitForRecordingFinish(timeout: TimeInterval) async throws {
        if recordingDidFinish {
            return
        }
        if let recordingFailure = recordingFailure {
            throw NativeRecordingError.recordingFailed(recordingFailure.localizedDescription)
        }

        try await withCheckedThrowingContinuation { continuation in
            self.finishContinuation = continuation

            self.finishTimeoutTask?.cancel()
            self.finishTimeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(timeout * 1_000_000_000)
                    )
                } catch {
                    return
                }
                self?.handleFinishTimeout()
            }
        }
    }

    /// Waits until the finalized movie is on disk and AVFoundation can open
    /// its container, then returns that asset. This deliberately does not wait
    /// for `recordingOutputDidFinishRecording`, which may be delayed or skipped
    /// after `stopCapture()` even when the file was written successfully.
    private func waitForFinalizedMovie(at url: URL) async throws -> AVURLAsset {
        let deadline = Date().addingTimeInterval(
            NativeRecordingLimits.finishTimeoutSeconds
        )
        var previousSize: Int64 = -1

        while true {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)

            if NativeRecordingFile.looksLikeFinalizedMovie(at: url),
               size > 0,
               size == previousSize {
                // The header and a stable size are necessary but not
                // sufficient: confirm AVFoundation can open the container.
                let asset = AVURLAsset(url: url)
                if let isPlayable = try? await asset.load(.isPlayable), isPlayable {
                    return asset
                }
            }

            previousSize = size

            if Date() >= deadline {
                throw NativeRecordingError.finishTimedOut
            }
            try await Task.sleep(
                nanoseconds: UInt64(
                    NativeRecordingLimits.finalizationPollIntervalSeconds
                        * 1_000_000_000
                )
            )
        }
    }

    private func exportAudio(from asset: AVAsset, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NativeRecordingError.recordingFailed("AVFoundation could not create an audio export session.")
        }
        guard session.supportedFileTypes.contains(.m4a) else {
            throw NativeRecordingError.recordingFailed("AVFoundation cannot write M4A audio.")
        }
        try await session.export(to: url, as: .m4a)
        restrictFile(url)
    }

    private func writePoster(
        from asset: AVAsset,
        duration: CMTime,
        fallbackDurationSeconds: TimeInterval,
        to url: URL
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_920, height: 1_920)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

        let fallbackDuration = duration.isValid && !duration.isIndefinite
            ? CMTimeGetSeconds(duration)
            : fallbackDurationSeconds
        var times: [CMTime] = [.zero]
        if fallbackDuration > 0.15 {
            times.append(CMTime(seconds: 0.1, preferredTimescale: 600))
        }
        if fallbackDuration > 0.5 {
            times.append(CMTime(seconds: fallbackDuration / 2, preferredTimescale: 600))
        }

        var lastError: Error?
        for time in times {
            do {
                let image = try await generator.image(at: time).image
                try writePNG(image, to: url)
                restrictFile(url)
                return
            } catch {
                lastError = error
            }
        }
        throw NativeRecordingError.posterExtractionFailed(
            lastError?.localizedDescription ?? "No video frame was available."
        )
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NativeRecordingError.posterExtractionFailed("A PNG destination could not be created.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NativeRecordingError.posterExtractionFailed("The PNG could not be finalized.")
        }
    }

    private func movieFileSize(at url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeRecordingError.recordingFileMissing
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else {
            throw NativeRecordingError.recordingFileEmpty
        }
        return size
    }

    // MARK: - Event handling

    private func handlePickerSelection(_ filter: SCContentFilter) {
        guard state == .choosingContent, let continuation = pickerContinuation else {
            return
        }
        pickerContinuation = nil
        picker.isActive = false
        continuation.resume(returning: filter)
    }

    private func handlePickerCancellation() {
        guard state == .choosingContent, let continuation = pickerContinuation else {
            return
        }
        pickerContinuation = nil
        picker.isActive = false
        continuation.resume(throwing: NativeRecordingError.cancelled)
    }

    private func handlePickerFailure(_ error: Error) {
        guard state == .choosingContent, let continuation = pickerContinuation else {
            return
        }
        pickerContinuation = nil
        picker.isActive = false
        continuation.resume(
            throwing: NativeRecordingError.contentSelectionFailed(error.localizedDescription)
        )
    }

    private func cancelPickerSelection() {
        picker.isActive = false
        guard let continuation = pickerContinuation else {
            return
        }
        pickerContinuation = nil
        continuation.resume(throwing: NativeRecordingError.cancelled)
    }

    private func handleRecordingStarted(_ output: SCRecordingOutput) {
        guard output === recordingOutput else {
            return
        }
        guard state == .preparing else {
            return
        }

        recordingStarted = true
        recordingStartDate = Date()
        state = .recording
        startTimeoutTask?.cancel()
        startTimeoutTask = nil

        if let startContinuation = startContinuation {
            self.startContinuation = nil
            startContinuation.resume()
        }

        startProgressMonitor()
        delegate?.recordingServiceDidStart(self)
    }

    private func handleRecordingFinished(_ output: SCRecordingOutput) {
        guard output === recordingOutput else {
            return
        }

        recordingDidFinish = true
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        if let finishContinuation = finishContinuation {
            self.finishContinuation = nil
            finishContinuation.resume()
        }

        monitorTask?.cancel()
        monitorTask = nil

        switch state {
        case .recording:
            _ = beginFinalization(reason: .recordingFinishedUnexpectedly)
        case .preparing:
            if let startContinuation = startContinuation {
                self.startContinuation = nil
                startContinuation.resume(
                    throwing: NativeRecordingError.recordingDidNotStart
                )
            }
            Task { @MainActor [weak self] in
                await self?.failSession(NativeRecordingError.recordingDidNotStart)
            }
        case .idle, .choosingContent, .stopping, .cancelling, .finished, .failed:
            break
        }
    }

    private func handleRecordingFailure(_ output: SCRecordingOutput) {
        guard output === recordingOutput else {
            return
        }

        // Do not dereference the framework's error. A malformed NSError at
        // ScreenCaptureKit teardown is a suspected crash source, so avoid
        // touching it before app code can surface anything. When a stop is
        // already underway, the file-on-disk path remains the source of truth.
        let recordingError = NativeRecordingError.recordingFailed(
            "The screen recorder reported a failure."
        )
        recordingFailure = recordingError
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        if let finishContinuation = finishContinuation {
            self.finishContinuation = nil
            finishContinuation.resume(throwing: recordingError)
        }
        if let startContinuation = startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: recordingError)
        }

        if state == .recording || state == .preparing {
            Task { @MainActor [weak self] in
                await self?.failSession(recordingError)
            }
        }
    }

    private func handleStreamStopped(_ stoppedStream: SCStream) {
        guard stoppedStream === stream else {
            return
        }

        streamStoppedBySystem = true
        let stopMessage = "macOS ended the capture."

        switch state {
        case .recording:
            pendingStopWarning = stopMessage
            _ = beginFinalization(reason: .screenCaptureStopped)
        case .preparing:
            if let startContinuation = startContinuation {
                self.startContinuation = nil
                startContinuation.resume(
                    throwing: NativeRecordingError.recordingStopped(stopMessage)
                )
            }
            Task { @MainActor [weak self] in
                await self?.failSession(
                    NativeRecordingError.recordingStopped(stopMessage)
                )
            }
        case .idle, .choosingContent, .stopping, .cancelling, .finished, .failed:
            break
        }
    }

    private var pendingStopWarning: String?

    private func handleStartTimeout() {
        guard state == .preparing, let startContinuation else {
            return
        }
        self.startContinuation = nil
        startTimeoutTask = nil
        startContinuation.resume(throwing: NativeRecordingError.recordingDidNotStart)
    }

    private func handleStartCancellation() {
        guard state == .preparing, let startContinuation else {
            return
        }
        self.startContinuation = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        startContinuation.resume(throwing: CancellationError())
    }

    private func handleFinishTimeout() {
        guard let finishContinuation else {
            return
        }
        self.finishContinuation = nil
        finishTimeoutTask = nil
        finishContinuation.resume(
            throwing: NativeRecordingError.finishTimedOut
        )
    }

    // MARK: - Progress

    private func startProgressMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            NativeRecordingLimits.progressIntervalSeconds * 1_000_000_000
                        )
                    )
                } catch {
                    return
                }

                guard let self, self.state == .recording else {
                    return
                }
                self.sampleProgress()
                guard self.state == .recording else {
                    return
                }
                if self.progress.elapsedSeconds >= NativeRecordingLimits.automaticStopDurationSeconds {
                    _ = self.beginFinalization(reason: .maximumDurationReached)
                    return
                }
                if self.progress.recordedBytes >= NativeRecordingLimits.automaticStopBytes {
                    _ = self.beginFinalization(reason: .maximumFileSizeReached)
                    return
                }
            }
        }
    }

    private func sampleProgress() {
        let recordedSeconds = recordingOutput
            .map { CMTimeGetSeconds($0.recordedDuration) } ?? 0
        let wallSeconds = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
        let elapsed = recordedSeconds.isFinite && recordedSeconds > 0
            ? recordedSeconds
            : wallSeconds
        let bytes = Int64(recordingOutput?.recordedFileSize ?? 0)

        let next = NativeRecordingProgress(
            elapsedSeconds: elapsed,
            recordedBytes: bytes,
            durationLimitFraction: min(
                elapsed / NativeRecordingLimits.maximumDurationSeconds,
                1
            ),
            sizeLimitFraction: min(
                Double(bytes) / Double(NativeRecordingLimits.maximumMovieBytes),
                1
            )
        )
        progress = next
        delegate?.recordingService(self, didUpdate: next)
    }

    // MARK: - Cleanup and errors

    private func stopTimers() {
        monitorTask?.cancel()
        monitorTask = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
    }

    private func stopStreamForCleanup() async {
        if let stream = stream, !streamStoppedBySystem {
            try? await stream.stopCapture()
        }
    }

    private func releaseCaptureObjects() {
        stream = nil
        recordingOutput = nil
    }

    private func failSession(_ error: NativeRecordingError) async {
        if state == .failed {
            return
        }
        if state == .cancelling {
            cleanupWorkingDirectory()
            return
        }

        state = .failed
        lastError = error
        stopTimers()

        picker.isActive = false

        if let pickerContinuation = pickerContinuation {
            self.pickerContinuation = nil
            pickerContinuation.resume(throwing: error)
        }
        if let startContinuation = startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: error)
        }
        if let finishContinuation = finishContinuation {
            self.finishContinuation = nil
            finishContinuation.resume(throwing: error)
        }

        await stopStreamForCleanup()
        releaseCaptureObjects()
        cleanupWorkingDirectory()

        if !failureNotified {
            failureNotified = true
            delegate?.recordingService(self, didFailWith: error)
        }
    }

    private func cancelSessionSilently() async {
        guard !isTearingDown else {
            return
        }
        isTearingDown = true
        defer { isTearingDown = false }

        stopTimers()
        picker.isActive = false
        state = .cancelling

        if let pickerContinuation = pickerContinuation {
            self.pickerContinuation = nil
            pickerContinuation.resume(throwing: CancellationError())
        }
        if let startContinuation = startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: CancellationError())
        }
        if let finishContinuation = finishContinuation {
            self.finishContinuation = nil
            finishContinuation.resume(throwing: CancellationError())
        }

        let needsDrain = recordingStarted && (stream != nil || recordingOutput != nil)
        await stopStreamForCleanup()
        if needsDrain && !recordingDidFinish {
            _ = try? await waitForRecordingFinish(
                timeout: NativeRecordingLimits.cancellationDrainTimeoutSeconds
            )
        }
        releaseCaptureObjects()
        cleanupWorkingDirectory()

        state = .idle
        progress = .zero
    }

    private func resetForNewSession() {
        stopTimers()
        picker.isActive = false
        picker.remove(self)

        pickerContinuation = nil
        startContinuation = nil
        finishContinuation = nil
        stream = nil
        recordingOutput = nil
        workingDirectory = nil
        finalizationTask = nil

        recordingStarted = false
        recordingDidFinish = false
        recordingFailure = nil
        streamStoppedBySystem = false
        recordingStartDate = nil
        failureNotified = false
        isTearingDown = false
        pendingStopWarning = nil
        progress = .zero
        lastResult = nil
        lastError = nil
    }

    private func normalizeStartError(_ error: Error) -> NativeRecordingError {
        if let recordingError = error as? NativeRecordingError {
            return recordingError
        }
        if error is CancellationError {
            return .cancelled
        }
        return .captureStartFailed(error.localizedDescription)
    }

    private func normalizeFinalizationError(_ error: Error) -> NativeRecordingError {
        if let recordingError = error as? NativeRecordingError {
            return recordingError
        }
        if error is CancellationError {
            return .cancelled
        }
        return .stopFailed(error.localizedDescription)
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HighliteRecording-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(values)
            return directory
        } catch {
            throw NativeRecordingError.temporaryDirectoryFailed(error.localizedDescription)
        }
    }

    private func cleanupWorkingDirectory() {
        guard let workingDirectory else {
            return
        }
        self.workingDirectory = nil
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private func restrictDirectoryContents(_ directory: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for item in contents {
            restrictFile(item)
        }
    }

    private func restrictFile(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - SCContentSharingPickerObserver

@available(macOS 15.0, *)
extension NativeRecordingService: SCContentSharingPickerObserver {
    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            self?.handlePickerSelection(filter)
        }
    }

    public nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            self?.handlePickerCancellation()
        }
    }

    public nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.handlePickerFailure(error)
        }
    }
}

// MARK: - SCRecordingOutputDelegate

@available(macOS 15.0, *)
extension NativeRecordingService: SCRecordingOutputDelegate {
    public nonisolated func recordingOutputDidStartRecording(
        _ recordingOutput: SCRecordingOutput
    ) {
        Task { @MainActor [weak self] in
            self?.handleRecordingStarted(recordingOutput)
        }
    }

    public nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: Error
    ) {
        // `error` is intentionally not captured or inspected. See
        // `handleRecordingFailure` for the suspected ScreenCaptureKit
        // teardown issue.
        Task { @MainActor [weak self] in
            self?.handleRecordingFailure(recordingOutput)
        }
    }

    public nonisolated func recordingOutputDidFinishRecording(
        _ recordingOutput: SCRecordingOutput
    ) {
        Task { @MainActor [weak self] in
            self?.handleRecordingFinished(recordingOutput)
        }
    }
}

// MARK: - SCStreamDelegate

@available(macOS 15.0, *)
extension NativeRecordingService: SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Do not capture `error`: dereferencing a malformed ScreenCaptureKit
        // NSError at stream teardown is a suspected crash path.
        Task { @MainActor [weak self] in
            self?.handleStreamStopped(stream)
        }
    }
}
