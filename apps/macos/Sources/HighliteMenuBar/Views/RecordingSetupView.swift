import SwiftUI

/// Explicit pre-recording choice. Microphone audio is off unless the user turns
/// it on here; system audio is never captured.
struct RecordingSetupView: View {
    let onStart: @MainActor (Bool) -> Void
    let onCancel: @MainActor () -> Void

    @State private var includeMicrophone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Record screen")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DashboardTheme.ink)
                Text("Choose one window or display with the macOS picker. Recording starts after you confirm the selection.")
                    .font(.callout)
                    .foregroundStyle(DashboardTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("The selected window or display is recorded as MP4 video.", systemImage: "rectangle.dashed")
                Label("System audio is never captured.", systemImage: "speaker.slash")
                Label("The menu bar shows a recording indicator and a Stop action.", systemImage: "record.circle")
                Label(
                    "Recording stops automatically at \(Int(NativeRecordingLimits.maximumDurationSeconds)) seconds or \(NativeRecordingLimits.maximumMovieBytes / (1_024 * 1_024)) MB and opens the review.",
                    systemImage: "timer"
                )
            }
            .font(.callout)
            .foregroundStyle(DashboardTheme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $includeMicrophone) {
                    Text("Record microphone audio")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(DashboardTheme.ink)
                }
                .toggleStyle(.switch)
                .accessibilityHint("Adds a separate microphone audio track to this recording")
                Text(
                    includeMicrophone
                        ? "macOS will ask for microphone permission if needed. The microphone track stays local with the video until you save."
                        : "Off by default. Highlite will not request or record microphone audio."
                )
                .font(.caption)
                .foregroundStyle(DashboardTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DashboardStyle.cardPadding)
            .background(DashboardTheme.surfaceMuted, in: RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.cardCornerRadius)
                    .strokeBorder(DashboardTheme.line, lineWidth: 1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Label("Nothing is saved until you review and choose Save to Highlite.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 12)
                Button("Cancel") {
                    Task { @MainActor in onCancel() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Choose Window or Display…") {
                    Task { @MainActor in onStart(includeMicrophone) }
                }
                .buttonStyle(HighlitePrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DashboardStyle.pagePadding)
        .background(DashboardTheme.canvas)
    }
}
