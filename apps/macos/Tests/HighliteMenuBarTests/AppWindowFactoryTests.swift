import AppKit
import SwiftUI
import XCTest
@testable import HighliteMenuBar

@MainActor
final class AppWindowFactoryTests: XCTestCase {
    func testWindowWithSmallRootViewKeepsRequestedContentGeometry() {
        _ = NSApplication.shared

        // A small intrinsic root view reproduces the macOS 15+ collapse: the
        // hosting controller is attached before SwiftUI has laid it out.
        let window = AppWindowFactory.makeWindow(
            title: "Test",
            contentSize: NSSize(width: 820, height: 700),
            minimumContentSize: NSSize(width: 780, height: 660),
            rootView: Text("Small")
        )
        window.updateConstraintsIfNeeded()

        assertContentGeometry(
            window,
            expected: NSSize(width: 820, height: 700),
            minimum: NSSize(width: 780, height: 660)
        )
    }

    func testDashboardWindowKeepsIntendedContentGeometry() {
        _ = NSApplication.shared
        let fixture = TestAppModel()
        defer { fixture.cleanUp() }

        let window = AppWindowFactory.makeDashboardWindow(model: fixture.model)
        window.updateConstraintsIfNeeded()

        assertContentGeometry(
            window,
            expected: AppWindowLayout.dashboardContentSize,
            minimum: AppWindowLayout.dashboardMinimumContentSize
        )
    }

    func testDashboardMinimumContentFitsLayoutIncludingDivider() {
        XCTAssertEqual(AppWindowLayout.sidebarMinimumWidth, 180)
        XCTAssertEqual(AppWindowLayout.detailMinimumWidth, 780)
        XCTAssertEqual(AppWindowLayout.splitViewDividerWidth, 1)
        XCTAssertEqual(AppWindowLayout.dashboardMinimumContentSize.width, 961)
        XCTAssertGreaterThanOrEqual(
            AppWindowLayout.dashboardMinimumContentSize.height,
            AppWindowLayout.detailMinimumHeight
        )
    }

    func testReviewWindowKeepsIntendedContentGeometry() {
        _ = NSApplication.shared
        let fixture = TestAppModel()
        defer { fixture.cleanUp() }

        let window = AppWindowFactory.makeReviewWindow(
            model: fixture.model,
            request: makeReviewRequest()
        )
        window.updateConstraintsIfNeeded()

        assertContentGeometry(
            window,
            expected: AppWindowLayout.reviewContentSize,
            minimum: AppWindowLayout.reviewMinimumContentSize
        )
    }

    func testReusedReviewWindowRestoresContentGeometry() {
        _ = NSApplication.shared
        let fixture = TestAppModel()
        defer { fixture.cleanUp() }

        let window = AppWindowFactory.makeReviewWindow(
            model: fixture.model,
            request: makeReviewRequest()
        )
        // Attaching a replacement controller is the reuse path that previously
        // inherited the hosting view's pre-layout size.
        AppWindowFactory.attachReview(makeReviewRequest(), model: fixture.model, to: window)
        window.updateConstraintsIfNeeded()

        assertContentGeometry(
            window,
            expected: AppWindowLayout.reviewContentSize,
            minimum: AppWindowLayout.reviewMinimumContentSize
        )
        XCTAssertEqual(window.contentMinSize, AppWindowLayout.reviewMinimumContentSize)
    }

    func testReviewMinimumContentMatchesReviewViewMinimums() {
        XCTAssertEqual(AppWindowLayout.reviewMinimumContentSize.width, 780)
        XCTAssertEqual(AppWindowLayout.reviewMinimumContentSize.height, 660)
        XCTAssertLessThanOrEqual(
            AppWindowLayout.reviewMinimumContentSize.width,
            AppWindowLayout.reviewContentSize.width
        )
        XCTAssertLessThanOrEqual(
            AppWindowLayout.reviewMinimumContentSize.height,
            AppWindowLayout.reviewContentSize.height
        )
    }

    private func assertContentGeometry(
        _ window: NSWindow,
        expected: NSSize,
        minimum: NSSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            window.contentLayoutRect.width,
            expected.width,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            window.contentLayoutRect.height,
            expected.height,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertEqual(window.contentMinSize, minimum, file: file, line: line)
        XCTAssertGreaterThan(window.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(window.frame.height, 0, file: file, line: line)
        XCTAssertFalse(window.isReleasedWhenClosed, file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.titled), file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.closable), file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.miniaturizable), file: file, line: line)
        XCTAssertTrue(window.styleMask.contains(.resizable), file: file, line: line)
    }
}
