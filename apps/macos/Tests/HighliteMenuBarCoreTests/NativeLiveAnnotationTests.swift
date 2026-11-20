import XCTest
@testable import HighliteMenuBarCore

final class NativeLiveAnnotationTests: XCTestCase {
    private func stroke(
        at milliseconds: Int,
        kind: NativeCaptureAnnotationKind = .freehand
    ) -> NativeLiveAnnotationStroke {
        NativeLiveAnnotationStroke(
            atMilliseconds: milliseconds,
            annotation: NativeCaptureAnnotation(
                kind: kind,
                points: [
                    NativeCapturePoint(x: 0.1, y: 0.1),
                    NativeCapturePoint(x: 0.6, y: 0.6),
                ]
            )
        )
    }

    func testPlannerGroupsStrokesInsideTheDuplicateFrameWindow() {
        let moments = NativeLiveAnnotationPlanner.moments(
            from: [stroke(at: 100), stroke(at: 300), stroke(at: 1_200), stroke(at: 1_600)],
            durationMilliseconds: 10_000,
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertEqual(moments.map(\.atMilliseconds), [500, 1_200])
        XCTAssertEqual(moments.map(\.annotations.count), [2, 2])
    }

    func testPlannerClampsTheFirstMomentAwayFromThePoster() {
        let moments = NativeLiveAnnotationPlanner.moments(
            from: [stroke(at: 50)],
            durationMilliseconds: 10_000,
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertEqual(moments.map(\.atMilliseconds), [500])
        XCTAssertEqual(moments.first?.annotations.count, 1)
    }

    func testPlannerCapsMomentsAndMergesOverflowIntoTheLastFrame() {
        let strokes = stride(from: 1_000, through: 10_000, by: 1_000).map {
            stroke(at: $0)
        }
        let moments = NativeLiveAnnotationPlanner.moments(
            from: strokes,
            durationMilliseconds: 21_000,
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertEqual(moments.count, 5)
        XCTAssertEqual(moments.last?.atMilliseconds, 5_000)
        XCTAssertEqual(moments.last?.annotations.count, 6)
    }

    func testPlannerDropsUnrenderableStrokes() {
        let tiny = NativeLiveAnnotationStroke(
            atMilliseconds: 1_000,
            annotation: NativeCaptureAnnotation(
                kind: .freehand,
                points: [NativeCapturePoint(x: 0.5, y: 0.5)]
            )
        )
        let moments = NativeLiveAnnotationPlanner.moments(
            from: [tiny],
            durationMilliseconds: 10_000,
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertTrue(moments.isEmpty)
    }

    func testPlannerClampsAStrokePastTheEndIntoTheLastPossibleFrame() {
        let moments = NativeLiveAnnotationPlanner.moments(
            from: [stroke(at: 12_000)],
            durationMilliseconds: 10_000,
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertEqual(moments.map(\.atMilliseconds), [10_000])
        XCTAssertEqual(moments.first?.annotations.count, 1)
    }

    func testPlannerNeedsRoomAfterThePoster() {
        let moments = NativeLiveAnnotationPlanner.moments(
            from: [stroke(at: 100)],
            durationMilliseconds: 300,
            imageWidth: 100,
            imageHeight: 100
        )

        XCTAssertTrue(moments.isEmpty)
    }
}
