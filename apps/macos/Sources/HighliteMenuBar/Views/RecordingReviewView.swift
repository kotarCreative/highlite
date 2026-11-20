import AppKit
import AVKit
import HighliteMenuBarCore
import SwiftUI

/// Native review window for one screen recording: AVKit playback, an optional
/// highlight on the still poster, a note, and an explicit save to the local
/// relay. Nothing is uploaded until Save to Highlite is chosen.
struct RecordingReviewView: View {
    @ObservedObject var draft: NativeRecordingDraft
    let onSave: @MainActor (NativeRecordingBundle) async throws -> SessionMetadata
    let onClose: @MainActor () -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                videoPane
                posterPane
            }
            .frame(maxHeight: .infinity)
            noteEditor
            if !draft.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(DashboardTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
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
        .onDisappear {
            draft.pause()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Review screen recording")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DashboardTheme.ink)
                Text("Play back the recording, optionally mark the still poster, and add a note. The recording stays local until you save it to the relay.")
                    .font(.callout)
                    .foregroundStyle(DashboardTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text(Self.durationText(draft.durationMilliseconds))
                Text("·")
                Text("\(draft.imageWidth) × \(draft.imageHeight) poster")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(DashboardTheme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DashboardTheme.neutralSoft, in: Capsule())
        }
    }

    private var videoPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Playback")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 8)
                Text(draft.hasMicrophoneAudio ? "Video + microphone audio" : "Video only")
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
            }
            VideoPlayer(player: draft.player)
                .frame(minHeight: 300, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius)
                        .strokeBorder(DashboardTheme.lineStrong, lineWidth: 1)
                }
                .accessibilityLabel("Recorded screen video")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var posterPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Poster mark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 8)
                Button("Clear") {
                    draft.highlight = nil
                }
                .buttonStyle(.link)
                .disabled(draft.highlight == nil)
                .accessibilityHint("Removes the poster highlight")
            }
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
                .accessibilityLabel("Still poster image")
                .accessibilityHint("Drag to add a highlight rectangle to the poster")
            }
            .frame(height: 240)
            Text("Optional. The poster becomes the session keyframe; drag once to mark the area that matters.")
                .font(.caption)
                .foregroundStyle(DashboardTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 330, alignment: .topLeading)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DashboardTheme.muted)
            TextField("What should someone notice here?", text: $draft.note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .accessibilityLabel("Recording note")
            HStack(alignment: .firstTextBaseline) {
                Text("The note becomes the session title and the poster label.")
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 8)
                Text("\(draft.note.count)/\(NativeRecordingBundleBuilder.maximumNoteLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        draft.note.count > NativeRecordingBundleBuilder.maximumNoteLength
                            ? DashboardTheme.danger
                            : DashboardTheme.muted
                    )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label(
                "MP4 video, poster, and optional microphone audio stay local until Save.",
                systemImage: "video"
            )
            .font(.caption)
            .foregroundStyle(DashboardTheme.muted)
            Spacer(minLength: 12)
            Button("Cancel") {
                Task { @MainActor in onClose() }
            }
            .disabled(isSaving)
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
            // Keep the draft and its temporary files so the user can retry.
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

    private static func durationText(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
