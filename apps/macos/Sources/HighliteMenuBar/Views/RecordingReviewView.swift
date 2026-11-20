import AppKit
import AVKit
import HighliteMenuBarCore
import SwiftUI

/// Native review window for one screen recording: AVKit playback, frame
/// capture at reviewed moments, the browser SDK's annotation tools, a note, and
/// an explicit save to the local relay. Nothing is uploaded until Save to
/// Highlite is chosen.
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
                framePane
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
                Text("Pause where something matters, add that frame, then draw with freehand, circle, arrow, or highlight. Strokes from the live annotation bar are added automatically. The recording stays local until you save it to the relay.")
                    .font(.callout)
                    .foregroundStyle(DashboardTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text(NativeRecordingDraft.timeText(draft.durationMilliseconds))
                Text("·")
                Text("\(draft.keyframeCount) frame\(draft.keyframeCount == 1 ? "" : "s")")
                Text("·")
                Text("\(draft.imageWidth) × \(draft.imageHeight)")
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
            transport
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    draft.togglePlayback()
                } label: {
                    Image(systemName: draft.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.bordered)
                .help(draft.isPlaying ? "Pause playback" : "Play recording")
                .accessibilityLabel(draft.isPlaying ? "Pause playback" : "Play recording")

                Slider(
                    value: Binding(
                        get: { Double(draft.playbackTimeMilliseconds) / 1_000 },
                        set: { draft.seek(toMilliseconds: Int(($0 * 1_000).rounded())) }
                    ),
                    in: 0...max(0.1, Double(draft.durationMilliseconds) / 1_000)
                )
                .accessibilityLabel("Playback position")

                Text(
                    "\(NativeRecordingDraft.timeText(draft.playbackTimeMilliseconds)) / \(NativeRecordingDraft.timeText(draft.durationMilliseconds))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(DashboardTheme.muted)
                .frame(minWidth: 92, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    Task { await captureFrame() }
                } label: {
                    Label(
                        draft.isCapturingFrame ? "Capturing frame…" : "Add frame from playhead",
                        systemImage: "camera"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(draft.isCapturingFrame || draft.isImportingLiveAnnotations || !draft.canAddMoment)
                .help("Pauses playback and captures the current frame for annotation")
                Spacer(minLength: 8)
                Text("Frames must be half a second from the poster and each other.")
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
            }
        }
    }

    private var framePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Annotate frame")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 8)
                Text(draft.selectedFrameLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DashboardTheme.muted)
            }
            frameSelector
            AnnotationCanvas(
                image: draft.selectedImage,
                imageWidth: draft.imageWidth,
                imageHeight: draft.imageHeight,
                annotations: draft.selectedAnnotations,
                selectedTool: draft.selectedTool,
                accessibilityLabel: "Recording frame for annotation",
                accessibilityHint: "Drag to draw with the selected annotation tool",
                canDraw: draft.selectedAnnotations.count < NativeCaptureAnnotationLimits.maximumAnnotations,
                onAddAnnotation: { draft.addAnnotation($0) }
            )
            .frame(minHeight: 280, maxHeight: .infinity)
            AnnotationToolbar(
                selectedTool: $draft.selectedTool,
                annotations: draft.selectedAnnotations,
                onUndo: draft.undoLastAnnotation,
                onClear: draft.clearAnnotations,
                compact: true
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                DashboardTheme.neutralSoft.opacity(0.55),
                in: RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.controlCornerRadius)
                    .strokeBorder(DashboardTheme.lineStrong, lineWidth: 1)
            }
            if let liveAnnotationStatus = draft.liveAnnotationStatus {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(liveAnnotationStatus)
                        .font(.caption)
                        .foregroundStyle(DashboardTheme.muted)
                }
            }
            Text("The poster is the opening frame. Each captured frame becomes its own keyframe, and annotations are burned into that keyframe by the canonical compiler.")
                .font(.caption)
                .foregroundStyle(DashboardTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 400, alignment: .topLeading)
    }

    private var frameSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                frameChip(
                    title: "Poster",
                    isSelected: draft.isPosterSelected
                ) {
                    draft.selectPoster()
                }
                ForEach(draft.moments) { moment in
                    HStack(spacing: 2) {
                        frameChip(
                            title: NativeRecordingDraft.timeText(moment.atMs),
                            isSelected: draft.selectedFrameID == moment.id,
                            drawsBackground: false
                        ) {
                            draft.selectMoment(id: moment.id)
                        }
                        Button {
                            draft.removeMoment(id: moment.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(
                                    draft.selectedFrameID == moment.id
                                        ? DashboardTheme.actionInk.opacity(0.75)
                                        : DashboardTheme.muted
                                )
                                .padding(.trailing, 7)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this captured frame")
                        .accessibilityLabel("Remove frame at \(NativeRecordingDraft.timeText(moment.atMs))")
                    }
                    .background(
                        draft.selectedFrameID == moment.id
                            ? DashboardTheme.action
                            : DashboardTheme.neutralSoft,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                draft.selectedFrameID == moment.id
                                    ? DashboardTheme.actionInk.opacity(0.8)
                                    : DashboardTheme.lineStrong,
                                lineWidth: 1
                            )
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 32)
        .accessibilityLabel("Captured frames")
    }

    private func frameChip(
        title: String,
        isSelected: Bool,
        drawsBackground: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(isSelected ? DashboardTheme.actionInk : DashboardTheme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    drawsBackground
                        ? (isSelected ? DashboardTheme.action : DashboardTheme.neutralSoft)
                        : Color.clear,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            drawsBackground
                                ? (isSelected
                                    ? DashboardTheme.actionInk.opacity(0.8)
                                    : DashboardTheme.lineStrong)
                                : Color.clear,
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                Text("The note becomes the session title and the target label.")
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
                "MP4 video, poster, captured frames, and optional microphone audio stay local until Save.",
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
    private func captureFrame() async {
        guard !draft.isCapturingFrame, !draft.isImportingLiveAnnotations else { return }
        errorMessage = nil
        do {
            try await draft.captureFrameForAnnotation()
        } catch {
            errorMessage = error.localizedDescription
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
}
