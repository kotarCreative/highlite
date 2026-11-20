import Combine
import Foundation
import HighliteMenuBarCore
import XCTest
@testable import HighliteMenuBar

@MainActor
final class NativeRecordingControllerTests: XCTestCase {
    func testStartAndStopSerializeOneRecordingFlow() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output.directory.deletingLastPathComponent()) }
        let recorder = MockScreenRecording(output: output)
        let controller = NativeRecordingController(recorder: recorder)

        XCTAssertEqual(controller.phase, .idle)
        try await controller.start(includeMicrophone: true)
        XCTAssertTrue(controller.isRecording)
        XCTAssertTrue(controller.includeMicrophone)
        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(recorder.requestedMicrophone, true)

        do {
            try await controller.start(includeMicrophone: false)
            XCTFail("A second recording must not start")
        } catch {
            XCTAssertEqual(error as? NativeRecordingControllerError, .busy)
        }

        let stopped = try await controller.stop()
        XCTAssertEqual(stopped.directory, output.directory)
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(controller.phase, .reviewing)
        XCTAssertFalse(controller.isRecording)

        controller.finishReview()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testStartAndStopFailuresReturnToIdle() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output.directory.deletingLastPathComponent()) }
        let recorder = MockScreenRecording(output: output)
        let controller = NativeRecordingController(recorder: recorder)

        recorder.startError = TestRecordingError.denied
        do {
            try await controller.start(includeMicrophone: false)
            XCTFail("The simulated start must fail")
        } catch {
            XCTAssertEqual(error as? TestRecordingError, .denied)
        }
        XCTAssertEqual(controller.phase, .idle)

        recorder.startError = nil
        try await controller.start(includeMicrophone: false)
        recorder.stopError = TestRecordingError.failedStop
        do {
            _ = try await controller.stop()
            XCTFail("The simulated stop must fail")
        } catch {
            XCTAssertEqual(error as? TestRecordingError, .failedStop)
        }
        XCTAssertEqual(controller.phase, .idle)
    }

    func testRecorderFinishAutomaticallyMovesToReview() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output.directory.deletingLastPathComponent()) }
        let recorder = MockScreenRecording(output: output)
        let controller = NativeRecordingController(recorder: recorder)

        let completed = expectation(description: "recorder finished")
        let cancellable = controller.$completedOutput
            .compactMap { $0 }
            .first()
            .sink { _ in completed.fulfill() }
        defer { cancellable.cancel() }

        try await controller.start(includeMicrophone: false)
        recorder.stateSubject.send(.finished)

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(controller.phase, .reviewing)
        XCTAssertEqual(controller.consumeCompletedOutput()?.directory, output.directory)
        controller.finishReview()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testShutdownCancelsAnActiveRecordingAndDeletesItsDirectory() async throws {
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output.directory.deletingLastPathComponent()) }
        let recorder = MockScreenRecording(output: output)
        let controller = NativeRecordingController(recorder: recorder)

        try await controller.start(includeMicrophone: false)
        await controller.shutdown()

        XCTAssertEqual(recorder.cancelCalls, 1)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.directory.path))
    }

    private func makeOutput() throws -> NativeRecordingOutput {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeRecordingControllerTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(
            "\(NativeRecordingTempStore.directoryPrefix)test",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return NativeRecordingOutput(
            directory: directory,
            movieURL: directory.appendingPathComponent("recording.mp4"),
            posterPNGURL: directory.appendingPathComponent("poster.png"),
            audioURL: nil,
            durationMilliseconds: 1_000,
            warnings: []
        )
    }
}

@MainActor
private final class MockScreenRecording: NativeScreenRecording {
    let output: NativeRecordingOutput
    let stateSubject = CurrentValueSubject<NativeRecordingState, Never>(.idle)
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var requestedMicrophone: Bool?
    var startError: Error?
    var stopError: Error?

    init(output: NativeRecordingOutput) {
        self.output = output
    }

    var statePublisher: AnyPublisher<NativeRecordingState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    func start(includeMicrophone: Bool) async throws {
        startCalls += 1
        requestedMicrophone = includeMicrophone
        if let startError {
            throw startError
        }
        stateSubject.send(.recording)
    }

    func stop() async throws -> NativeRecordingOutput {
        stopCalls += 1
        if let stopError {
            throw stopError
        }
        stateSubject.send(.finished)
        return output
    }

    func cancel() async {
        cancelCalls += 1
        try? FileManager.default.removeItem(at: output.directory)
        stateSubject.send(.idle)
    }
}

private enum TestRecordingError: LocalizedError, Equatable {
    case denied
    case failedStop

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Microphone permission was denied."
        case .failedStop:
            return "The recording could not be finalized."
        }
    }
}
