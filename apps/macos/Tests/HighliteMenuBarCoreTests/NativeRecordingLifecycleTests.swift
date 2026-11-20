import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class NativeRecordingLifecycleTests: XCTestCase {
    func testFileStabilityRequiresTwoEqualPositiveSamples() {
        var stability = NativeRecordingFileStability()

        XCTAssertFalse(stability.observe(fileSize: 0))
        XCTAssertFalse(stability.observe(fileSize: 128))
        XCTAssertTrue(stability.observe(fileSize: 128))
        XCTAssertFalse(stability.observe(fileSize: 256))
        XCTAssertTrue(stability.observe(fileSize: 256))
    }

    func testFileStabilityResetsWhenTheFileDisappears() {
        var stability = NativeRecordingFileStability()

        XCTAssertFalse(stability.observe(fileSize: 64))
        XCTAssertTrue(stability.observe(fileSize: 64))
        XCTAssertFalse(stability.observe(fileSize: 0))
        XCTAssertFalse(stability.observe(fileSize: 64))
        XCTAssertTrue(stability.observe(fileSize: 64))
    }

    func testStopGateAllowsExactlyOneStopRequest() {
        var gate = NativeRecordingStopGate()

        XCTAssertFalse(gate.hasRequestedStop)
        XCTAssertTrue(gate.beginStop(streamAlreadyStopped: false))
        XCTAssertTrue(gate.hasRequestedStop)
        XCTAssertFalse(gate.beginStop(streamAlreadyStopped: false))

        gate.reset()
        XCTAssertFalse(gate.hasRequestedStop)
        XCTAssertTrue(gate.beginStop(streamAlreadyStopped: false))
    }

    func testStopGateSkipsAStreamThatAlreadyStopped() {
        var gate = NativeRecordingStopGate()

        XCTAssertFalse(gate.beginStop(streamAlreadyStopped: true))
        XCTAssertFalse(gate.hasRequestedStop)
    }
}
