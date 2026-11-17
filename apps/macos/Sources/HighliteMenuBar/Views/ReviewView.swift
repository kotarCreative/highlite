import SwiftUI
import HighliteMenuBarCore

struct ReviewView: View {
    @ObservedObject var model: AppModel
    let request: ReviewRequest
    @State private var targetID: String
    @State private var showSendConfirmation = false

    init(model: AppModel, request: ReviewRequest) {
        self.model = model
        self.request = request
        _targetID = State(initialValue: request.defaultTargetId ?? "")
    }

    private var selectedTarget: OpenCodeCandidate? {
        request.targets.first { $0.sessionId == targetID }
    }

    private var pickerTargets: [OpenCodeCandidate] {
        if let pinned = request.pinnedTargetID {
            return request.targets.filter { $0.sessionId == pinned }
        }
        return request.targets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(
                "Confirm OpenCode send",
                subtitle: "Nothing has been sent automatically."
            ) {
                StatusPill(text: request.run.status.label, color: request.run.status.color)
            }

            Text("Capture: \(request.sessionTitle)")
                .font(.callout)
            Text("Run revision \(request.run.revision)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let suggestion = request.run.suggestion {
                Card("AI suggestion") {
                    HStack {
                        Text(suggestion.title)
                            .font(.callout.weight(.medium))
                        StatusPill(
                            text: suggestion.confidence.rawValue.capitalized,
                            color: suggestion.confidence == .high ? .green : (suggestion.confidence == .medium ? .orange : .secondary)
                        )
                    }
                    Text(suggestion.directory)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(suggestion.reason)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } else {
                Card("Manual target") {
                    Text("No AI target matched confidently. Choose one of the eligible existing sessions below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Card("Target session") {
                if request.targets.isEmpty {
                    Text("This run has no eligible target sessions. Regenerate the run in the dashboard.")
                        .foregroundStyle(.red)
                } else {
                    Picker("Send to", selection: $targetID) {
                        ForEach(pickerTargets) { candidate in
                            Text("\(candidate.title) — \(candidate.projectName)")
                                .tag(candidate.sessionId)
                        }
                    }
                    .disabled(!request.allowsTargetOverride)
                    if let pinned = request.pinnedTargetID, !request.allowsTargetOverride {
                        Text("This rejected run is pinned to the target it was sent to. Changing the target requires regenerating the suggestion.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if selectedTarget == nil {
                            Text("Pinned session \(pinned) is not in the current discovered candidate list. Regenerate before retrying.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    if let selectedTarget {
                        Text(selectedTarget.title)
                            .font(.callout.weight(.medium))
                        Text(selectedTarget.directory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(selectedTarget.sessionId)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("Only sessions discovered for this exact project directory are listed. The relay revalidates the target before invoking OpenCode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Exact prompt")
                    .font(.headline)
                Spacer()
                CopyButton(title: "Copy prompt", value: request.run.promptPreview)
            }

            CodeBlock(
                text: request.run.promptPreview.isEmpty
                    ? "No prompt text is stored for this run."
                    : request.run.promptPreview,
                scrolls: true,
                minHeight: 160
            )

            if let error = model.reviewError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Text("The relay sends this stored prompt text unchanged to the selected existing session. The message ID is deterministic, but a timeout can still make delivery uncertain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Defer") {
                    model.deferCurrentReview()
                }
                .disabled(model.isBusy("review-submit"))
                Spacer()
                Button("Cancel and defer") {
                    model.deferCurrentReview()
                }
                .disabled(model.isBusy("review-submit"))
                Button("Send to OpenCode…") {
                    showSendConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !request.canSubmit(targetSessionID: targetID)
                        || model.isBusy("review-submit")
                )
            }
        }
        .padding(DashboardStyle.pagePadding)
        .frame(minWidth: 780, minHeight: 660)
        .alert("Send this exact prompt?", isPresented: $showSendConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Send") {
                Task {
                    await model.submitReview(request: request, targetSessionId: targetID)
                }
            }
        } message: {
            Text(
                "Target: \(selectedTarget?.title ?? targetID)\nDirectory: \(selectedTarget?.directory ?? "unknown")\n\nThis queues the prompt in OpenCode. It cannot be recalled."
            )
        }
    }
}
