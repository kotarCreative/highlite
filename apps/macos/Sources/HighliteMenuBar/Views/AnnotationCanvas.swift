import AppKit
import HighliteMenuBarCore
import SwiftUI

/// The browser SDK's four annotation tools, shared by still-capture and
/// recording review. The selected tool applies to the next drag.
struct AnnotationToolbar: View {
    @Binding var selectedTool: NativeCaptureAnnotationKind
    let annotations: [NativeCaptureAnnotation]
    let onUndo: () -> Void
    let onClear: () -> Void
    /// The recording frame pane is narrow, so it uses icon-only tools while
    /// keeping the same four annotation kinds and undo/clear actions.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            ForEach(NativeCaptureAnnotationKind.allCases, id: \.self) { kind in
                toolButton(kind)
            }
            Spacer(minLength: compact ? 4 : 12)
            if compact {
                if !annotations.isEmpty {
                    Text("\(annotations.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DashboardTheme.muted)
                }
                compactActionButton(
                    "arrow.uturn.backward",
                    help: "Removes the most recent annotation",
                    isDisabled: annotations.isEmpty,
                    action: onUndo
                )
                compactActionButton(
                    "trash",
                    help: "Removes every annotation",
                    isDisabled: annotations.isEmpty,
                    action: onClear
                )
            } else {
                Text(
                    annotations.isEmpty
                        ? "No annotations yet"
                        : "\(annotations.count) annotation\(annotations.count == 1 ? "" : "s")"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(DashboardTheme.muted)
                Button("Undo", action: onUndo)
                    .buttonStyle(.link)
                    .disabled(annotations.isEmpty)
                    .help("Removes the most recent annotation")
                Button("Clear", action: onClear)
                    .buttonStyle(.link)
                    .disabled(annotations.isEmpty)
                    .help("Removes every annotation")
            }
        }
    }

    private func toolButton(_ kind: NativeCaptureAnnotationKind) -> some View {
        let isSelected = selectedTool == kind
        return Button {
            selectedTool = kind
        } label: {
            Group {
                if compact {
                    Image(systemName: kind.systemImage)
                } else {
                    Label(kind.title, systemImage: kind.systemImage)
                }
            }
            .font(
                compact
                    ? Font.system(size: 12, weight: .semibold)
                    : Font.callout.weight(.medium)
            )
            .frame(
                width: compact ? CGFloat(26) : nil,
                height: compact ? CGFloat(24) : nil
            )
            .padding(.horizontal, compact ? 0 : 10)
            .padding(.vertical, compact ? 0 : 6)
            .foregroundStyle(isSelected ? DashboardTheme.actionInk : DashboardTheme.ink)
            .background(
                RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
                    .fill(isSelected ? DashboardTheme.action : DashboardTheme.neutralSoft)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
                    .strokeBorder(
                        isSelected
                            ? DashboardTheme.actionInk.opacity(0.8)
                            : DashboardTheme.lineStrong,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .help(kind.help)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func compactActionButton(
        _ systemName: String,
        help: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(
                    isDisabled ? DashboardTheme.muted.opacity(0.5) : DashboardTheme.ink
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One image with its annotations and a drag-to-draw surface. The image is
/// aspect-fit into the available space; every stored point stays normalized so
/// the canonical compiler remains the only renderer of the saved bundle.
struct AnnotationCanvas: View {
    let image: NSImage
    let imageWidth: Int
    let imageHeight: Int
    let annotations: [NativeCaptureAnnotation]
    let selectedTool: NativeCaptureAnnotationKind
    let accessibilityLabel: String
    let accessibilityHint: String
    let canDraw: Bool
    let onAddAnnotation: (NativeCaptureAnnotation) -> Bool

    @State private var drawingKind: NativeCaptureAnnotationKind?
    @State private var drawingPoints: [NativeCapturePoint] = []

    var body: some View {
        GeometryReader { proxy in
            let fitted = AnnotationGeometry.fittedRect(
                width: imageWidth,
                height: imageHeight,
                in: proxy.size
            )
            ZStack(alignment: .topLeading) {
                DashboardTheme.neutralSoft
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                Canvas { context, _ in
                    for annotation in annotations {
                        AnnotationGeometry.draw(annotation, in: &context, fitted: fitted)
                    }
                    if let drawingKind, drawingPoints.count >= 2 {
                        AnnotationGeometry.draw(
                            NativeCaptureAnnotation(
                                kind: drawingKind,
                                points: drawingPoints
                            ),
                            in: &context,
                            fitted: fitted,
                            opacity: 0.7
                        )
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius)
                    .strokeBorder(DashboardTheme.lineStrong, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in
                        guard canDraw else { return }
                        updateDrawing(
                            from: value.startLocation,
                            to: value.location,
                            fitted: fitted
                        )
                    }
                    .onEnded { value in
                        guard canDraw else {
                            resetDrawing()
                            return
                        }
                        finishDrawing(
                            from: value.startLocation,
                            to: value.location,
                            fitted: fitted
                        )
                    }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
        }
    }

    private func updateDrawing(from start: CGPoint, to end: CGPoint, fitted: CGRect) {
        guard fitted.width > 0, fitted.height > 0 else { return }
        if drawingKind == nil {
            drawingKind = selectedTool
            drawingPoints = [AnnotationGeometry.normalizedPoint(start, in: fitted)]
        }
        let point = AnnotationGeometry.normalizedPoint(end, in: fitted)
        if drawingKind == .freehand {
            if drawingPoints.last != point {
                drawingPoints.append(point)
            }
        } else if let first = drawingPoints.first {
            drawingPoints = [first, point]
        }
    }

    private func finishDrawing(from start: CGPoint, to end: CGPoint, fitted: CGRect) {
        guard fitted.width > 0, fitted.height > 0 else {
            resetDrawing()
            return
        }
        let kind = drawingKind ?? selectedTool
        var points = drawingPoints
        if points.isEmpty {
            points = [AnnotationGeometry.normalizedPoint(start, in: fitted)]
        }
        let last = AnnotationGeometry.normalizedPoint(end, in: fitted)
        if kind == .freehand {
            if points.last != last {
                points.append(last)
            }
        } else {
            points = [points.first ?? last, last]
        }
        _ = onAddAnnotation(NativeCaptureAnnotation(kind: kind, points: points))
        resetDrawing()
    }

    private func resetDrawing() {
        drawingKind = nil
        drawingPoints = []
    }
}

/// Geometry and drawing shared by the review surfaces. All calculations use
/// the fitted image rect, never the surrounding letterbox.
enum AnnotationGeometry {
    static func normalizedPoint(_ point: CGPoint, in fitted: CGRect) -> NativeCapturePoint {
        let x = min(max((point.x - fitted.minX) / fitted.width, 0), 1)
        let y = min(max((point.y - fitted.minY) / fitted.height, 0), 1)
        return NativeCapturePoint(x: Double(x), y: Double(y))
    }

    static func fittedRect(width: Int, height: Int, in size: CGSize) -> CGRect {
        guard width > 0, height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / CGFloat(width), size.height / CGFloat(height))
        let fitted = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    static func displayPoint(_ point: NativeCapturePoint, in fitted: CGRect) -> CGPoint {
        CGPoint(
            x: fitted.minX + CGFloat(point.x) * fitted.width,
            y: fitted.minY + CGFloat(point.y) * fitted.height
        )
    }

    static func draw(
        _ annotation: NativeCaptureAnnotation,
        in context: inout GraphicsContext,
        fitted: CGRect,
        opacity: Double = 1
    ) {
        let points = annotation.points.map { displayPoint($0, in: fitted) }
        guard let first = points.first, let last = points.last, points.count >= 2 else { return }
        let ink = DashboardTheme.primary.opacity(opacity)
        let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)

        switch annotation.kind {
        case .freehand:
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(ink), style: stroke)
        case .circle:
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            var path = Path()
            path.addEllipse(in: rect)
            context.stroke(path, with: .color(ink), style: stroke)
        case .highlight:
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            var path = Path()
            path.addRect(rect)
            context.fill(path, with: .color(DashboardTheme.highlightYellow.opacity(0.38 * opacity)))
            context.stroke(path, with: .color(ink), style: stroke)
        case .arrow:
            var path = Path()
            path.move(to: first)
            path.addLine(to: last)
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
            path.addLine(to: left)
            path.move(to: last)
            path.addLine(to: right)
            context.stroke(path, with: .color(ink), style: stroke)
        }
    }
}

extension NativeCaptureAnnotationKind {
    var title: String {
        switch self {
        case .freehand: return "Freehand"
        case .circle: return "Circle"
        case .arrow: return "Arrow"
        case .highlight: return "Highlight"
        }
    }

    var systemImage: String {
        switch self {
        case .freehand: return "pencil.tip"
        case .circle: return "circle"
        case .arrow: return "arrow.up.right"
        case .highlight: return "highlighter"
        }
    }

    var help: String {
        switch self {
        case .freehand: return "Draw a freehand stroke"
        case .circle: return "Drag to outline an area with a circle"
        case .arrow: return "Drag to point at something"
        case .highlight: return "Drag to shade an area"
        }
    }
}
