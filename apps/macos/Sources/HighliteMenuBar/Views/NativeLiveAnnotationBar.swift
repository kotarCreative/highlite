import Foundation
import HighliteMenuBarCore
import SwiftUI

/// Compact floating controls shown while a screen recording is running.
/// The bar uses icon-only tools so it fits over narrow windows and keeps the
/// four browser annotation tools reachable without leaving the recording.
@MainActor
struct NativeLiveAnnotationBar: View {
    @ObservedObject var session: NativeLiveAnnotationSession
    let recordingStartedAt: Date
    let onStop: () -> Void

    private let accent = Color(red: 0.94, green: 1.00, blue: 0.24)
    private let accentInk = Color(red: 0.19, green: 0.14, blue: 0.18)
    private let stopRed = Color(red: 0.77, green: 0.13, blue: 0.18)

    var body: some View {
        HStack(spacing: 6) {
            recordingClock
            separator
            annotateButton
            separator
            ForEach(NativeCaptureAnnotationKind.allCases, id: \.self) { kind in
                toolButton(kind)
            }
            separator
            iconButton(
                systemName: "arrow.uturn.backward",
                label: "Undo last annotation",
                isDisabled: session.strokes.isEmpty
            ) {
                session.undo()
            }
            iconButton(
                systemName: "trash",
                label: "Clear all annotations",
                isDisabled: session.strokes.isEmpty
            ) {
                session.clear()
            }
            separator
            stopButton
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live annotation tools")
    }

    private var recordingClock: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stopRed)
                .frame(width: 7, height: 7)
            Text("REC")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.78))
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(elapsedText(at: context.date))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityValue(Text(elapsedText(at: Date())))
    }

    private var annotateButton: some View {
        Button {
            session.toggleAnnotating()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: session.isAnnotating ? "checkmark" : "pencil.tip")
                    .font(.system(size: 12, weight: .bold))
                Text(session.isAnnotating ? "Done" : "Annotate")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(session.isAnnotating ? accentInk : Color.white.opacity(0.94))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                session.isAnnotating ? accent : Color.white.opacity(0.12),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(
            session.isAnnotating
                ? "Finish drawing and let clicks reach the recorded app again"
                : "Draw on the recording area; drawing mode captures mouse drags"
        )
        .accessibilityLabel(session.isAnnotating ? "Done annotating" : "Annotate recording")
    }

    private func toolButton(_ kind: NativeCaptureAnnotationKind) -> some View {
        let isSelected = session.selectedTool == kind
        return Button {
            session.selectedTool = kind
        } label: {
            Image(systemName: kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 27, height: 26)
                .foregroundStyle(isSelected ? accentInk : Color.white.opacity(0.92))
                .background(
                    isSelected ? accent : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .help(kind.help)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func iconButton(
        systemName: String,
        label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 25, height: 26)
                .foregroundStyle(
                    Color.white.opacity(isDisabled ? 0.3 : 0.9)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private var stopButton: some View {
        Button(action: onStop) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(stopRed, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop recording and review the result")
        .accessibilityLabel("Stop recording")
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 18)
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(recordingStartedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
