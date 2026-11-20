import AppKit
import SwiftUI
import HighliteMenuBarCore

/// Native review window for one still capture: preview, one highlight
/// rectangle, a note, and an explicit save to the local relay.
struct CaptureReviewView: View {
    @ObservedObject var draft: NativeCaptureDraft
    let onSave: @MainActor (NativeCaptureBundle) async throws -> SessionMetadata
    let onClose: @MainActor () -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            preview
            noteEditor
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(DashboardTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(DashboardStyle.pagePadding)
        .background(DashboardTheme.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review screen capture")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DashboardTheme.ink)
                Text("Drag on the image to highlight one area. The capture stays local until you save it to the relay.")
                    .font(.callout)
                    .foregroundStyle(DashboardTheme.muted)
            }
            Spacer(minLength: 12)
            Text("\(draft.imageWidth) × \(draft.imageHeight) px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(DashboardTheme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DashboardTheme.neutralSoft, in: Capsule())
        }
    }

    private var preview: some View {
        GeometryReader { proxy in
            let fitted = Self.fittedRect(
                width: draft.imageWidth,
                height: draft.imageHeight,
                in: proxy.size
            )
            ZStack(alignment: .topLeading) {
                DashboardTheme.neutralSoft
                Image(nsImage: draft.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                if let highlight = draft.highlight {
                    let display = Self.displayRect(highlight, in: fitted)
                    Rectangle()
                        .fill(DashboardTheme.highlightYellow.opacity(0.38))
                        .overlay {
                            Rectangle()
                                .strokeBorder(DashboardTheme.primary, lineWidth: 2)
                        }
                        .frame(width: display.width, height: display.height)
                        .position(x: display.midX, y: display.midY)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius)
                    .strokeBorder(DashboardTheme.lineStrong, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        updateHighlight(
                            from: value.startLocation,
                            to: value.location,
                            fitted: fitted
                        )
                    }
            )
            .accessibilityLabel("Captured screen image")
            .accessibilityHint("Drag to add a highlight rectangle")
        }
        .frame(minHeight: 340, maxHeight: .infinity)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DashboardTheme.muted)
            TextField("What should someone notice here?", text: $draft.note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
                .accessibilityLabel("Capture note")
            HStack(alignment: .firstTextBaseline) {
                Text(
                    draft.highlight == nil
                        ? "Add one highlight rectangle and a note to save."
                        : "The note becomes the session title and highlights the marked region."
                )
                .font(.caption)
                .foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 8)
                Text("\(draft.note.count)/\(NativeCaptureBundleBuilder.maximumNoteLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        draft.note.count > NativeCaptureBundleBuilder.maximumNoteLength
                            ? DashboardTheme.danger
                            : DashboardTheme.muted
                    )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("Still image only — no video, microphone, or page DOM.", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(DashboardTheme.muted)
            Spacer(minLength: 12)
            Button("Cancel") {
                Task { @MainActor in onClose() }
            }
            .keyboardShortcut(.cancelAction)
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Save to Highlite")
                }
            }
            .buttonStyle(HighlitePrimaryButtonStyle())
            .disabled(!draft.canSave || isSaving)
            .keyboardShortcut(.defaultAction)
        }
    }

    @MainActor
    private func save() async {
        guard !isSaving, draft.canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let bundle = try draft.makeBundle()
            _ = try await onSave(bundle)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateHighlight(from start: CGPoint, to end: CGPoint, fitted: CGRect) {
        guard fitted.width > 0, fitted.height > 0 else { return }
        let first = Self.normalizedPoint(start, in: fitted)
        let last = Self.normalizedPoint(end, in: fitted)
        let rect = NativeCaptureRect(
            x: min(first.x, last.x),
            y: min(first.y, last.y),
            width: abs(last.x - first.x),
            height: abs(last.y - first.y)
        )
        if rect.width * Double(draft.imageWidth) >= 2,
           rect.height * Double(draft.imageHeight) >= 2 {
            draft.highlight = rect
        }
    }

    private static func normalizedPoint(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        let x = min(max((point.x - fitted.minX) / fitted.width, 0), 1)
        let y = min(max((point.y - fitted.minY) / fitted.height, 0), 1)
        return CGPoint(x: x, y: y)
    }

    private static func fittedRect(width: Int, height: Int, in size: CGSize) -> CGRect {
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

    private static func displayRect(_ highlight: NativeCaptureRect, in fitted: CGRect) -> CGRect {
        CGRect(
            x: fitted.minX + CGFloat(highlight.x) * fitted.width,
            y: fitted.minY + CGFloat(highlight.y) * fitted.height,
            width: CGFloat(highlight.width) * fitted.width,
            height: CGFloat(highlight.height) * fitted.height
        )
    }
}
