import AppKit
import SwiftUI
import HighliteMenuBarCore

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

    static let captureContentSize = NSSize(width: 960, height: 760)
    // The annotation tool row sits above the preview; keep enough height that the
    // preview, note, and footer remain visible at the minimum window size.
    static let captureMinimumContentSize = NSSize(width: 720, height: 660)

    static let recordingSetupContentSize = NSSize(width: 580, height: 500)
    static let recordingSetupMinimumContentSize = NSSize(width: 540, height: 460)

    static let recordingReviewContentSize = NSSize(width: 1_000, height: 820)
    static let recordingReviewMinimumContentSize = NSSize(width: 820, height: 700)
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

    static func makeCaptureWindow(
        draft: NativeCaptureDraft,
        onSave: @escaping @MainActor (NativeCaptureBundle) async throws -> SessionMetadata,
        onClose: @escaping @MainActor () -> Void
    ) -> NSWindow {
        makeWindow(
            title: "Review screen capture",
            contentSize: AppWindowLayout.captureContentSize,
            minimumContentSize: AppWindowLayout.captureMinimumContentSize,
            rootView: CaptureReviewView(
                draft: draft,
                onSave: onSave,
                onClose: onClose
            )
        )
    }

    static func makeRecordingSetupWindow(
        onStart: @escaping @MainActor (Bool) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) -> NSWindow {
        makeWindow(
            title: "Record screen",
            contentSize: AppWindowLayout.recordingSetupContentSize,
            minimumContentSize: AppWindowLayout.recordingSetupMinimumContentSize,
            rootView: RecordingSetupView(
                onStart: onStart,
                onCancel: onCancel
            )
        )
    }

    static func makeRecordingReviewWindow(
        draft: NativeRecordingDraft,
        onSave: @escaping @MainActor (NativeRecordingBundle) async throws -> SessionMetadata,
        onClose: @escaping @MainActor () -> Void
    ) -> NSWindow {
        makeWindow(
            title: "Review screen recording",
            contentSize: AppWindowLayout.recordingReviewContentSize,
            minimumContentSize: AppWindowLayout.recordingReviewMinimumContentSize,
            rootView: RecordingReviewView(
                draft: draft,
                onSave: onSave,
                onClose: onClose
            )
        )
    }
}
