import AppKit
import SwiftUI

/// Shared geometry for AppKit windows and the SwiftUI views they host.
///
/// The window minimums are expressed in content coordinates and derived from
/// the layout minimums, including the split-view divider, so the window can
/// always satisfy both column minimums.
enum AppWindowLayout {
    static let sidebarMinimumWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 200
    static let sidebarMaximumWidth: CGFloat = 240

    static let detailMinimumWidth: CGFloat = 780
    static let detailMinimumHeight: CGFloat = 580

    /// One point per NavigationSplitView/NSSplitView divider.
    static let splitViewDividerWidth: CGFloat = 1

    static let dashboardContentSize = NSSize(width: 1_040, height: 760)
    static let dashboardMinimumContentSize = NSSize(
        width: sidebarMinimumWidth + detailMinimumWidth + splitViewDividerWidth,
        height: detailMinimumHeight
    )

    static let reviewContentSize = NSSize(width: 820, height: 700)
    static let reviewMinimumContentSize = NSSize(width: 780, height: 660)
}

@MainActor
enum AppWindowFactory {
    static func makeWindow<Content: View>(
        title: String,
        contentSize: NSSize,
        minimumContentSize: NSSize,
        rootView: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        setRootView(
            rootView,
            in: window,
            contentSize: contentSize,
            minimumContentSize: minimumContentSize
        )
        return window
    }

    /// Attaches a SwiftUI view controller and restores the intended geometry.
    ///
    /// Assigning `contentViewController` resizes the window to the hosting
    /// view's current frame. On macOS 15 and later SwiftUI resolves layout
    /// lazily, so that frame can still be zero. Resolve the constraints and
    /// then set the content size explicitly so neither the first window nor a
    /// reused window can collapse.
    static func setRootView<Content: View>(
        _ rootView: Content,
        in window: NSWindow,
        contentSize: NSSize,
        minimumContentSize: NSSize
    ) {
        let hosting = NSHostingController(rootView: rootView)
        // AppKit owns the window geometry. The default `.standardBounds` lets
        // SwiftUI's content constraints rewrite contentMinSize/contentMaxSize.
        hosting.sizingOptions = []

        window.contentViewController = hosting
        window.updateConstraintsIfNeeded()
        window.contentMinSize = minimumContentSize
        window.setContentSize(contentSize)
    }

    static func makeDashboardWindow(model: AppModel) -> NSWindow {
        makeWindow(
            title: "Highlite",
            contentSize: AppWindowLayout.dashboardContentSize,
            minimumContentSize: AppWindowLayout.dashboardMinimumContentSize,
            rootView: DashboardView(model: model)
        )
    }

    static func makeReviewWindow(model: AppModel, request: ReviewRequest) -> NSWindow {
        makeWindow(
            title: "Confirm OpenCode send",
            contentSize: AppWindowLayout.reviewContentSize,
            minimumContentSize: AppWindowLayout.reviewMinimumContentSize,
            rootView: ReviewView(model: model, request: request)
        )
    }

    static func attachReview(_ request: ReviewRequest, model: AppModel, to window: NSWindow) {
        setRootView(
            ReviewView(model: model, request: request),
            in: window,
            contentSize: AppWindowLayout.reviewContentSize,
            minimumContentSize: AppWindowLayout.reviewMinimumContentSize
        )
    }
}
