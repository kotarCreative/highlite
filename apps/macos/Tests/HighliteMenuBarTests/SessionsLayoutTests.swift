import AppKit
import SwiftUI
import XCTest
@testable import HighliteMenuBar

@MainActor
final class SessionsLayoutTests: XCTestCase {
    func testSessionsListAndPlaceholderFillProposedHeight() {
        _ = NSApplication.shared
        let fixture = TestAppModel()
        defer { fixture.cleanUp() }
        fixture.model.sessions = [makeSession()]

        let controller = NSHostingController(rootView: SessionsView(model: fixture.model))
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: NSSize(width: 900, height: 600))

        XCTAssertEqual(size.width, 900, accuracy: 1)
        XCTAssertEqual(size.height, 600, accuracy: 1)
    }

    func testSessionsDetailPanesFillProposedHeight() {
        _ = NSApplication.shared
        let fixture = TestAppModel()
        defer { fixture.cleanUp() }
        fixture.model.sessions = [makeSession()]
        fixture.model.selectedSessionID = "session-1"

        let controller = NSHostingController(rootView: SessionsView(model: fixture.model))
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: NSSize(width: 900, height: 600))

        XCTAssertEqual(size.width, 900, accuracy: 1)
        XCTAssertEqual(size.height, 600, accuracy: 1)
    }

    func testDashboardDetailFillsProposedWindowContent() {
        _ = NSApplication.shared
        let fixture = TestAppModel()
        defer { fixture.cleanUp() }

        let controller = NSHostingController(rootView: DashboardView(model: fixture.model))
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: AppWindowLayout.dashboardContentSize)

        XCTAssertEqual(size.width, AppWindowLayout.dashboardContentSize.width, accuracy: 1)
        XCTAssertEqual(size.height, AppWindowLayout.dashboardContentSize.height, accuracy: 1)
    }
}
