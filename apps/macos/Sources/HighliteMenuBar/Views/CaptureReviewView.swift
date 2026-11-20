import AppKit
import SwiftUI
import HighliteMenuBarCore

/// Native review window for one still capture: preview, the browser SDK's
/// annotation tools, a note, and an explicit save to the local relay.
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
                Text("Draw with freehand, circle, arrow, or highlight. The capture stays local until you save it to the relay.")
                    .font(.callout)
                    .foregroundStyle(DashboardTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 8) {
            AnnotationCanvas(
                image: draft.image,
                imageWidth: draft.imageWidth,
                imageHeight: draft.imageHeight,
                annotations: draft.annotations,
                selectedTool: draft.selectedTool,
                accessibilityLabel: "Captured screen image",
                accessibilityHint: "Drag to draw with the selected annotation tool",
                canDraw: draft.annotations.count < NativeCaptureBundleBuilder.maximumAnnotationCount,
                onAddAnnotation: { draft.addAnnotation($0) }
            )
            .frame(minHeight: 300, maxHeight: .infinity)

            AnnotationToolbar(
                selectedTool: $draft.selectedTool,
                annotations: draft.annotations,
                onUndo: draft.undoLastAnnotation,
                onClear: draft.clearAnnotations
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                DashboardTheme.neutralSoft.opacity(0.55),
                in: RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
                    .strokeBorder(DashboardTheme.lineStrong, lineWidth: 1)
            }
        }
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
                    draft.annotations.isEmpty
                        ? "Add at least one annotation and a note to save."
                        : "The note becomes the session title; annotations are burned into the compiled keyframe."
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

}
