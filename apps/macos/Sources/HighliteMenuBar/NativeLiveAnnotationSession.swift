import AppKit
import Combine
import HighliteMenuBarCore
import SwiftUI

/// Owns the live recording chrome: a floating annotate bar pinned to the
/// bottom of the captured window or display, plus a transparent drawing
/// surface over that same area.
///
/// The bar is always visible while capture is running. The drawing surface is
/// click-through until **Annotate** is chosen, so ordinary recording keeps
/// normal pointer behavior. Completed strokes are retained with their offsets
/// from the recording start and later converted into annotated keyframes in the
/// existing recording bundle.
@MainActor
final class NativeLiveAnnotationSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isAnnotating = false
    @Published var selectedTool: NativeCaptureAnnotationKind = .highlight {
        didSet {
            overlayView?.selectedTool = selectedTool
        }
    }
    @Published private(set) var strokes: [NativeLiveAnnotationStroke] = []
    @Published private(set) var startedAt: Date? = nil

    private var overlayWindow: NSWindow?
    private var overlayView: NativeLiveAnnotationOverlayView?
    private var toolbarWindow: NSPanel?
    private var onStop: (() -> Void)?

    var canUndo: Bool { !strokes.isEmpty }
    var strokeCount: Int { strokes.count }

    /// Shows the bar and overlay over the capture area. Safe to call only
    /// after the recorder reports that capture has actually started.
    func begin(
        recordingStartedAt: Date,
        captureArea: NativeRecordingCaptureArea?,
        onStop: @escaping () -> Void
    ) {
        cancel()
        startedAt = recordingStartedAt
        self.onStop = onStop
        isActive = true

        let area = NativeLiveAnnotationGeometry.areaRect(from: captureArea)
        makeOverlay(area: area)
        makeToolbar(area: area, recordingStartedAt: recordingStartedAt)
    }

    func toggleAnnotating() {
        setAnnotating(!isAnnotating)
    }

    func setAnnotating(_ annotating: Bool) {
        guard isActive else { return }
        isAnnotating = annotating
        overlayView?.acceptsDrawing = annotating
        overlayWindow?.ignoresMouseEvents = !annotating
        if annotating {
            overlayWindow?.orderFrontRegardless()
        }
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        refreshOverlay()
    }

    func clear() {
        guard !strokes.isEmpty else { return }
        strokes.removeAll()
        refreshOverlay()
    }

    /// Hides the chrome as soon as stopping begins, so the finalization window
    /// is not kept on screen. The strokes stay available for the review.
    func pauseForStop() {
        guard isActive else { return }
        isAnnotating = false
        isActive = false
        hideWindows()
    }

    /// Returns the strokes captured for this recording and tears down the
    /// chrome. Called once the finalized output is ready for review.
    func finish() -> [NativeLiveAnnotationStroke] {
        let result = strokes
        isAnnotating = false
        isActive = false
        startedAt = nil
        strokes = []
        hideWindows()
        return result
    }

    func cancel() {
        isAnnotating = false
        isActive = false
        startedAt = nil
        strokes = []
        onStop = nil
        hideWindows()
    }

    // MARK: - Windows

    private func makeOverlay(area: CGRect) {
        guard area.width > 0, area.height > 0 else { return }

        let window = NativeLiveAnnotationPanel(
            contentRect: area,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        // Best-effort privacy hint. ScreenCaptureKit may still include the
        // transparent overlay in display captures; keyframes remain the
        // authoritative annotation record either way.
        window.sharingType = NSWindow.SharingType.none

        let view = NativeLiveAnnotationOverlayView(
            frame: CGRect(origin: .zero, size: area.size)
        )
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.autoresizingMask = [.width, .height]
        view.selectedTool = selectedTool
        view.onStroke = { [weak self] kind, points, startedAt in
            self?.recordStroke(kind: kind, points: points, startedAt: startedAt)
        }
        window.contentView = view
        window.setFrame(area, display: false)

        overlayWindow = window
        overlayView = view
        window.orderFrontRegardless()
    }

    private func makeToolbar(area: CGRect, recordingStartedAt: Date) {
        let bar = NativeLiveAnnotationBar(
            session: self,
            recordingStartedAt: recordingStartedAt,
            onStop: { [weak self] in
                self?.onStop?()
            }
        )
        let hosting = NSHostingView(rootView: bar)
        hosting.layoutSubtreeIfNeeded()

        let fitted = hosting.fittingSize
        let size = fitted.width > 1 && fitted.height > 1
            ? fitted
            : NSSize(width: 560, height: 44)

        let panel = NativeLiveAnnotationPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        panel.sharingType = NSWindow.SharingType.none
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let resolved = hosting.fittingSize
        panel.setContentSize(
            resolved.width > 1 && resolved.height > 1 ? resolved : size
        )
        place(panel, in: area)

        toolbarWindow = panel
        panel.orderFrontRegardless()
    }

    private func place(_ panel: NSPanel, in area: CGRect) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(area) })
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? area
        let minimumX = visible.minX + 8
        let maximumX = max(minimumX, visible.maxX - size.width - 8)
        let minimumY = visible.minY + 8
        let maximumY = max(minimumY, visible.maxY - size.height - 8)

        let x = min(max(area.midX - size.width / 2, minimumX), maximumX)
        let y = min(max(area.minY + 16, minimumY), maximumY)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hideWindows() {
        overlayWindow?.orderOut(nil)
        toolbarWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil
        toolbarWindow = nil
    }

    // MARK: - Strokes

    private func recordStroke(
        kind: NativeCaptureAnnotationKind,
        points: [NativeCapturePoint],
        startedAt strokeStartedAt: Date
    ) {
        guard isActive, isAnnotating, let startedAt else { return }
        let annotation = NativeCaptureAnnotation(kind: kind, points: points)
        let width = max(1, Int((overlayView?.bounds.width ?? 1).rounded()))
        let height = max(1, Int((overlayView?.bounds.height ?? 1).rounded()))
        guard annotation.isRenderable(imageWidth: width, imageHeight: height) else {
            return
        }
        let elapsed = strokeStartedAt.timeIntervalSince(startedAt)
        guard elapsed.isFinite else { return }
        let atMilliseconds = max(0, Int((elapsed * 1_000).rounded()))
        guard strokes.count < 256 else { return }
        strokes.append(
            NativeLiveAnnotationStroke(
                atMilliseconds: atMilliseconds,
                annotation: annotation
            )
        )
        refreshOverlay()
    }

    private func refreshOverlay() {
        overlayView?.annotations = strokes.map(\.annotation)
    }
}

private final class NativeLiveAnnotationPanel: NSPanel {
    // Nonactivating panels can take key focus for their controls without
    // bringing the menu bar app forward. The overlay view only asks for first
    // mouse when drawing is enabled.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Translates ScreenCaptureKit's top-left, screen-point rectangle into AppKit's
/// bottom-left global coordinate space for the overlay and floating bar.
@MainActor
enum NativeLiveAnnotationGeometry {
    static func areaRect(from captureArea: NativeRecordingCaptureArea?) -> CGRect {
        guard let captureArea,
              captureArea.contentRect.width.isFinite,
              captureArea.contentRect.height.isFinite,
              captureArea.contentRect.origin.x.isFinite,
              captureArea.contentRect.origin.y.isFinite,
              captureArea.contentRect.width > 1,
              captureArea.contentRect.height > 1
        else {
            return NSScreen.screens.first?.frame
                ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        }

        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let content = captureArea.contentRect
        return CGRect(
            x: content.minX,
            y: mainHeight - content.maxY,
            width: content.width,
            height: content.height
        )
    }
}

/// A transparent, flipped drawing surface. It sits above the captured content
/// but only accepts mouse events while annotation mode is on.
private final class NativeLiveAnnotationOverlayView: NSView {
    var annotations: [NativeCaptureAnnotation] = [] {
        didSet { needsDisplay = true }
    }
    var selectedTool: NativeCaptureAnnotationKind = .highlight
    var acceptsDrawing = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onStroke: ((NativeCaptureAnnotationKind, [NativeCapturePoint], Date) -> Void)?

    private var drawingKind: NativeCaptureAnnotationKind?
    private var drawingPoints: [NativeCapturePoint] = []
    private var drawingStartedAt: Date?

    private let ink = NSColor(
        srgbRed: 0.66,
        green: 0.10,
        blue: 0.35,
        alpha: 1
    )
    private let highlight = NSColor(
        srgbRed: 0.94,
        green: 1.00,
        blue: 0.24,
        alpha: 1
    )

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if acceptsDrawing {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        NSBezierPath(rect: dirtyRect).fill()

        for annotation in annotations {
            draw(annotation, opacity: 1)
        }
        if let drawingKind, drawingPoints.count >= 2 {
            draw(
                NativeCaptureAnnotation(kind: drawingKind, points: drawingPoints),
                opacity: 0.72
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsDrawing else { return }
        drawingKind = selectedTool
        drawingStartedAt = Date()
        drawingPoints = [normalized(convert(event.locationInWindow, from: nil))]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsDrawing, drawingKind != nil else { return }
        let point = normalized(convert(event.locationInWindow, from: nil))
        if drawingKind == .freehand {
            if let last = drawingPoints.last {
                let dx = (point.x - last.x) * Double(bounds.width)
                let dy = (point.y - last.y) * Double(bounds.height)
                if (dx * dx + dy * dy).squareRoot() >= 1 {
                    drawingPoints.append(point)
                }
            } else {
                drawingPoints = [point]
            }
        } else if let first = drawingPoints.first {
            drawingPoints = [first, point]
        } else {
            drawingPoints = [point]
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsDrawing, let kind = drawingKind else {
            resetDrawing()
            return
        }
        let end = normalized(convert(event.locationInWindow, from: nil))
        if drawingPoints.isEmpty {
            drawingPoints = [end]
        } else if kind == .freehand {
            if drawingPoints.last != end {
                drawingPoints.append(end)
            }
        } else {
            drawingPoints = [drawingPoints[0], end]
        }

        let annotation = NativeCaptureAnnotation(
            kind: kind,
            points: drawingPoints
        )
        if annotation.isRenderable(
            imageWidth: max(1, Int(bounds.width)),
            imageHeight: max(1, Int(bounds.height))
        ) {
            onStroke?(kind, drawingPoints, drawingStartedAt ?? Date())
        }
        resetDrawing()
    }

    private func resetDrawing() {
        drawingKind = nil
        drawingPoints = []
        drawingStartedAt = nil
        needsDisplay = true
    }

    private func normalized(_ point: NSPoint) -> NativeCapturePoint {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        return NativeCapturePoint(
            x: min(max(Double(point.x / width), 0), 1),
            y: min(max(Double(point.y / height), 0), 1)
        )
    }

    private func draw(_ annotation: NativeCaptureAnnotation, opacity: CGFloat) {
        let points = annotation.points.map { point in
            CGPoint(
                x: CGFloat(point.x) * bounds.width,
                y: CGFloat(point.y) * bounds.height
            )
        }
        guard let first = points.first,
              let last = points.last,
              points.count >= 2
        else {
            return
        }

        let stroke = ink.withAlphaComponent(opacity)
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch annotation.kind {
        case .freehand:
            path.move(to: first)
            for point in points.dropFirst() {
                path.line(to: point)
            }
            stroke.setStroke()
            path.stroke()
        case .circle:
            let rect = boundingRect(from: first, to: last)
            let circle = NSBezierPath(ovalIn: rect)
            circle.lineWidth = 4
            circle.lineCapStyle = .round
            circle.lineJoinStyle = .round
            stroke.setStroke()
            circle.stroke()
        case .highlight:
            let rect = boundingRect(from: first, to: last)
            highlight.withAlphaComponent(0.38 * opacity).setFill()
            NSBezierPath(rect: rect).fill()
            path.appendRect(rect)
            stroke.setStroke()
            path.stroke()
        case .arrow:
            path.move(to: first)
            path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let headLength = CGFloat(NativeCaptureAnnotationLimits.arrowHeadLength)
            let spread = CGFloat.pi / 6
            let left = CGPoint(
                x: last.x - headLength * cos(angle - spread),
                y: last.y - headLength * sin(angle - spread)
            )
            let right = CGPoint(
                x: last.x - headLength * cos(angle + spread),
                y: last.y - headLength * sin(angle + spread)
            )
            path.move(to: last)
            path.line(to: left)
            path.move(to: last)
            path.line(to: right)
            stroke.setStroke()
            path.stroke()
        }
    }

    private func boundingRect(from first: CGPoint, to last: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
    }
}
