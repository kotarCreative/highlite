import Combine
import Foundation
import HighliteMenuBarCore

/// The finalized output of one screen recording. The recorder owns the files
/// in `directory` until the review window is dismissed or the app sweeps stale
/// directories on a later launch.
struct NativeRecordingOutput: Sendable {
    let directory: URL
    let movieURL: URL
    let posterPNGURL: URL
    let audioURL: URL?
    let durationMilliseconds: Int
    /// Non-fatal notes from post-processing, such as a requested microphone
    /// track that did not reach the movie.
    let warnings: [String]
}

enum NativeRecordingState: Equatable {
    case idle
    case choosing
    case preparing
    case recording
    case stopping
    case finished
    case failed
}

/// Small seam between app lifecycle/UI and the ScreenCaptureKit recorder.
@MainActor
protocol NativeScreenRecording: AnyObject {
    var statePublisher: AnyPublisher<NativeRecordingState, Never> { get }
    /// The selected window or display rectangle, available once capture starts.
    var captureArea: NativeRecordingCaptureArea? { get }
    func start(includeMicrophone: Bool) async throws
    func stop() async throws -> NativeRecordingOutput
    func cancel() async
}

@MainActor
extension NativeScreenRecording {
    var captureArea: NativeRecordingCaptureArea? { nil }
}

/// Narrow adapter over `NativeRecordingService`.
///
/// The recorder is macOS 15+ and exposes `start(includeMicrophone:)`,
/// `stop() -> NativeRecordingResult`, `cancel()`, and its published state. Only
/// this adapter knows the concrete result field names, so a recorder change
/// cannot ripple through the app lifecycle or review UI.
@MainActor
@available(macOS 15.0, *)
final class NativeRecordingServiceAdapter: NativeScreenRecording {
    private let service: NativeRecordingService

    init(service: NativeRecordingService? = nil) {
        // Construct the service in the main-actor-isolated initializer body.
        // A `NativeRecordingService()` default argument would be evaluated in
        // a synchronous nonisolated context, which Swift rejects because the
        // service's initializer is main-actor isolated.
        self.service = service ?? NativeRecordingService()
    }

    var statePublisher: AnyPublisher<NativeRecordingState, Never> {
        service.$state
            .map { state in
                switch state {
                case .idle:
                    return .idle
                case .choosingContent:
                    return .choosing
                case .preparing:
                    return .preparing
                case .recording:
                    return .recording
                case .stopping, .cancelling:
                    return .stopping
                case .finished:
                    return .finished
                case .failed:
                    return .failed
                }
            }
            .eraseToAnyPublisher()
    }

    var captureArea: NativeRecordingCaptureArea? {
        service.captureArea
    }

    func start(includeMicrophone: Bool) async throws {
        try await service.start(includeMicrophone: includeMicrophone)
    }

    func stop() async throws -> NativeRecordingOutput {
        let result = try await service.stop()
        guard let posterURL = result.posterURL else {
            // The review needs a poster for marking. Do not leak the finalized
            // movie when post-processing failed to produce one.
            result.discard()
            throw NativeRecordingError.posterExtractionFailed(
                result.warnings.last ?? "No poster frame was available."
            )
        }
        return NativeRecordingOutput(
            directory: result.directoryURL,
            movieURL: result.movieURL,
            posterPNGURL: posterURL,
            audioURL: result.audioURL,
            durationMilliseconds: result.durationMilliseconds,
            warnings: result.warnings
        )
    }

    func cancel() async {
        await service.cancel()
    }
}

/// Keeps the app usable on its macOS 14 floor. The menu disables recording and
/// explains the requirement before this recorder is ever asked to start.
@MainActor
private final class UnsupportedNativeScreenRecorder: NativeScreenRecording {
    var statePublisher: AnyPublisher<NativeRecordingState, Never> {
        Just(.idle).eraseToAnyPublisher()
    }

    func start(includeMicrophone: Bool) async throws {
        throw NativeRecordingControllerError.unsupportedOperatingSystem
    }

    func stop() async throws -> NativeRecordingOutput {
        throw NativeRecordingControllerError.unsupportedOperatingSystem
    }

    func cancel() async {}
}

enum NativeRecordingControllerError: LocalizedError, Equatable {
    case busy
    case notRecording
    case unsupportedOperatingSystem

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Finish the current screen flow before starting another recording."
        case .notRecording:
            return "There is no active screen recording to stop."
        case .unsupportedOperatingSystem:
            return "Screen recording requires macOS 15 or newer."
        }
    }
}

/// Serializes the recording lifecycle and publishes enough state for the menu
/// bar chrome. Exactly one screen flow can be active at a time.
@MainActor
final class NativeRecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case choosing
        case recording(startedAt: Date, includeMicrophone: Bool)
        case stopping
        case reviewing
    }

    @Published private(set) var phase: Phase = .idle
    /// Set when the recorder finishes on its own (45-second or 48 MiB budget,
    /// or a system stop). The app opens the review window from this value.
    @Published private(set) var completedOutput: NativeRecordingOutput?
    /// Set only when an unsolicited recorder failure needs surfacing.
    @Published private(set) var failureMessage: String?

    private let recorder: any NativeScreenRecording
    private var cancellables: Set<AnyCancellable> = []
    private var isFinalizingAutomatically = false

    init(recorder: (any NativeScreenRecording)? = nil) {
        if let recorder {
            self.recorder = recorder
        } else if #available(macOS 15.0, *) {
            self.recorder = NativeRecordingServiceAdapter()
        } else {
            self.recorder = UnsupportedNativeScreenRecorder()
        }
        self.recorder.statePublisher
            .sink { [weak self] state in
                Task { @MainActor in self?.handleRecorderState(state) }
            }
            .store(in: &cancellables)
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isActive: Bool {
        phase != .idle
    }

    var includeMicrophone: Bool {
        if case .recording(_, let includeMicrophone) = phase {
            return includeMicrophone
        }
        return false
    }

    /// The selected capture rectangle for the active recording. The overlay
    /// is presentation-only; the recorder remains the source of truth.
    var captureArea: NativeRecordingCaptureArea? {
        recorder.captureArea
    }

    func start(includeMicrophone: Bool) async throws {
        guard phase == .idle else {
            throw NativeRecordingControllerError.busy
        }
        failureMessage = nil
        completedOutput = nil
        phase = .choosing
        do {
            try await recorder.start(includeMicrophone: includeMicrophone)
            phase = .recording(startedAt: Date(), includeMicrophone: includeMicrophone)
        } catch {
            phase = .idle
            throw error
        }
    }

    func stop() async throws -> NativeRecordingOutput {
        guard case .recording = phase else {
            throw NativeRecordingControllerError.notRecording
        }
        phase = .stopping
        do {
            let output = try await recorder.stop()
            completedOutput = output
            phase = .reviewing
            return output
        } catch {
            phase = .idle
            throw error
        }
    }

    func consumeCompletedOutput() -> NativeRecordingOutput? {
        let output = completedOutput
        completedOutput = nil
        return output
    }

    func clearFailureMessage() {
        failureMessage = nil
    }

    func finishReview() {
        guard phase == .reviewing || phase == .stopping else { return }
        completedOutput = nil
        phase = .idle
    }

    /// Best-effort cleanup for app termination. The recorder's `cancel` stops
    /// an active picker or capture and deletes its private workspace, including
    /// a finalization already in flight.
    func shutdown() async {
        guard isActive else { return }
        if let output = completedOutput {
            NativeRecordingTempStore.remove(output.directory)
        }
        await recorder.cancel()
        completedOutput = nil
        failureMessage = nil
        phase = .idle
    }

    private func handleRecorderState(_ state: NativeRecordingState) {
        switch state {
        case .finished:
            // The recorder enforces its own duration and file-size budget. It
            // may finish without the user pressing Stop.
            guard case .recording = phase, !isFinalizingAutomatically else { return }
            isFinalizingAutomatically = true
            phase = .stopping
            Task { [weak self] in
                guard let self else { return }
                do {
                    let output = try await self.recorder.stop()
                    self.completedOutput = output
                    self.phase = .reviewing
                } catch {
                    self.failureMessage = error.localizedDescription
                    self.phase = .idle
                }
                self.isFinalizingAutomatically = false
            }
        case .failed:
            guard case .recording = phase else { return }
            phase = .stopping
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.recorder.stop()
                } catch {
                    self.failureMessage = error.localizedDescription
                }
                self.phase = .idle
            }
        case .idle:
            if case .recording = phase {
                phase = .idle
            }
        case .choosing, .preparing, .recording, .stopping:
            break
        }
    }
}
