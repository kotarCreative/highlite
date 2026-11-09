import SwiftUI
import HighliteMenuBarCore

struct SessionsView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedSessionID },
            set: { value in
                guard let value else { return }
                Task { await model.selectSession(value) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Captured sessions")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await model.refreshSessions() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.relay.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if model.sessions.isEmpty {
                EmptyHint(
                    title: "No captures yet",
                    detail: "Upload a browser capture to the relay. Sessions appear here after compilation."
                )
                .padding()
                Spacer()
            } else {
                HSplitView {
                    List(model.sessions, selection: selection) { session in
                        SessionRow(session: session)
                            .tag(session.sessionId)
                    }
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)

                    if let selected = model.selectedSession {
                        SessionDetailView(model: model, session: selected)
                    } else {
                        EmptyHint(
                            title: "Select a session",
                            detail: "Open a capture to review Jira drafts and OpenCode suggestions."
                        )
                        .frame(minWidth: 480)
                    }
                }
            }
        }
        .task {
            if model.sessions.isEmpty {
                await model.refreshSessions()
            }
            if let id = model.selectedSessionID {
                await model.refreshJiraRun(sessionId: id)
                await model.refreshOpenCodeRun(sessionId: id)
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                Text(session.pageTitle ?? "Untitled capture")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Text(Display.relative(session.receivedAtMs))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = session.pageUrl, !url.isEmpty {
                Text(url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: SessionMetadata

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(session.pageTitle ?? "Untitled capture")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        StatusPill(text: session.status.label, color: session.status.color)
                    }
                    if let url = session.pageUrl, !url.isEmpty {
                        Text(url)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 14) {
                        Text("Received \(Display.date(session.receivedAtMs))")
                        Text(Display.bytes(session.bytes))
                        Text("Duration \(Display.duration(session.durationMs))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let error = session.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let summary = session.summary, !summary.isEmpty {
                    Card("Capture summary") {
                        Text(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }

                JiraRunSection(model: model, session: session)
                OpenCodeRunSection(model: model, session: session)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: session.sessionId) {
            await model.refreshJiraRun(sessionId: session.sessionId)
            await model.refreshOpenCodeRun(sessionId: session.sessionId)
        }
    }
}

private struct JiraRunSection: View {
    @ObservedObject var model: AppModel
    let session: SessionMetadata
    @State private var showPublish = false
    @State private var summary = ""
    @State private var description = ""
    @State private var syncedRevision = -1
    @State private var syncedUpdatedAt: Int64 = -1

    private var run: JiraRun? { model.jiraRuns[session.sessionId] }

    private var draftIsDirty: Bool {
        guard let draft = run?.draft else { return false }
        return summary != draft.summary || description != draft.description
    }

    var body: some View {
        Card("Jira issue") {
            if let run {
                HStack {
                    StatusPill(text: run.status.label, color: run.status.color)
                    Text("Revision \(run.revision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if run.status == .failed || run.status == .draft {
                        Button(run.status == .failed ? "Regenerate" : "Generate again") {
                            Task { await model.startJiraDraft(sessionId: session.sessionId) }
                        }
                        .disabled(model.isBusy("jira-start"))
                    }
                }

                if let error = run.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if run.status == .queued || run.status == .analyzing || run.status == .publishing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(run.status == .publishing ? "Publishing to Jira..." : "Generating a draft from the capture...")
                            .foregroundStyle(.secondary)
                    }
                }

                if let provider = run.provider {
                    Text("\(provider.id) · \(provider.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let draft = run.draft {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.caption.weight(.semibold))
                        TextField("Summary", text: $summary)
                            .textFieldStyle(.roundedBorder)
                        Text("Description")
                            .font(.caption.weight(.semibold))
                        TextEditor(text: $description)
                            .font(.body)
                            .frame(minHeight: 150)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.15))
                            }
                    }

                    HStack {
                        Button("Save draft") {
                            Task {
                                _ = await model.saveJiraDraft(
                                    sessionId: session.sessionId,
                                    revision: run.revision,
                                    draft: JiraDraft(summary: summary, description: description)
                                )
                            }
                        }
                        .disabled(
                            run.status != .draft
                                || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isBusy("jira-draft")
                        )

                        Button("Publish to Jira") {
                            showPublish = true
                        }
                        .disabled(run.status != .draft || draftIsDirty || model.isBusy("jira-publish"))

                        Spacer()

                        if let issueUrl = run.issueUrl, let url = URL(string: issueUrl) {
                            Link("Open \(run.issueKey ?? "issue")", destination: url)
                        }
                    }

                    if run.status == .draft {
                        Text(draftIsDirty
                            ? "Save the edited draft before publishing."
                            : "Publishing uses this saved revision.")
                            .font(.caption)
                            .foregroundStyle(draftIsDirty ? Color.orange : Color.secondary)
                    }
                    if let draft = run.draft {
                        Text("Draft loaded: \(draft.summary.count) summary characters, \(draft.description.count) description characters.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if run.status == .published, let issueKey = run.issueKey {
                    Text("Published \(issueKey)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                }
                if run.status == .publishUnknown {
                    Text("Publication is uncertain. Check Jira for the issue before trying again; the relay will not retry automatically.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if run.status == .draft, let draft = run.draft {
                    Text("Draft preview: \(draft.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("No Jira draft for this capture yet.")
                    .foregroundStyle(.secondary)
                Button("Generate Jira draft") {
                    Task { await model.startJiraDraft(sessionId: session.sessionId) }
                }
                .disabled(model.isBusy("jira-start") || !model.relay.isRunning)
                Text("Configure the Jira recipe and a default AI provider first. Draft generation is reviewed before publication.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Publish this draft to Jira?", isPresented: $showPublish) {
            Button("Cancel", role: .cancel) {}
            Button("Publish") {
                guard let run else { return }
                Task {
                    _ = await model.publishJira(sessionId: session.sessionId, revision: run.revision)
                }
            }
        } message: {
            Text("This creates a Jira issue in \(run?.settings.jira.projectKey ?? "the configured project").")
        }
        .onAppear { syncDraft() }
        .onChange(of: run?.revision) { _, _ in syncDraft() }
        .onChange(of: run?.updatedAtMs) { _, _ in syncDraft() }
    }

    private func syncDraft() {
        guard let run, let draft = run.draft else { return }
        if syncedRevision != run.revision || syncedUpdatedAt != run.updatedAtMs {
            syncedRevision = run.revision
            syncedUpdatedAt = run.updatedAtMs
            summary = draft.summary
            description = draft.description
        }
    }
}

private struct OpenCodeRunSection: View {
    @ObservedObject var model: AppModel
    let session: SessionMetadata

    private var run: OpenCodeRun? { model.openCodeRuns[session.sessionId] }

    private var analysisInputsChanged: Bool {
        guard let run, let current = model.openCodeConfig?.recipe.settings else {
            return false
        }
        return run.settings.analysisInputsChanged(comparedTo: current)
    }

    private var canRegenerate: Bool {
        guard let run else { return false }
        return run.status == .failed
            || (run.status == .suggested && analysisInputsChanged)
    }

    var body: some View {
        Card("OpenCode suggestion") {
            if let run {
                HStack {
                    StatusPill(text: run.status.label, color: run.status.color)
                    Text("Revision \(run.revision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if canRegenerate {
                        Button(run.status == .failed ? "Regenerate suggestion" : "Regenerate with saved settings") {
                            Task { await model.startOpenCodeRun(sessionId: session.sessionId) }
                        }
                        .disabled(model.isBusy("opencode-start"))
                    }
                }

                if run.status == .suggested, analysisInputsChanged {
                    Text("Saved OpenCode settings changed since this suggestion. Regenerating creates a new revision; otherwise this suggestion remains the review target.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if run.status == .submitted || run.status == .submitUnknown {
                    Text("This run is terminal and cannot be analyzed again, even if recipe settings change. It remains as the delivery record.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = run.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if run.status == .queued || run.status == .analyzing || run.status == .submitting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(run.status == .submitting ? "Submitting after confirmation..." : "Ranking eligible sessions from bounded metadata...")
                            .foregroundStyle(.secondary)
                    }
                }

                if let suggestion = run.suggestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Suggested target")
                            .font(.caption.weight(.semibold))
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
                            .textSelection(.enabled)
                        Text(suggestion.reason)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                } else if run.status == .suggested {
                    Text("No AI target was selected. Choose any eligible session manually in the confirmation window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let target = run.opencodeTitle ?? run.suggestion?.title {
                    Text("Current target: \(target)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if run.status == .suggested {
                    HStack {
                        Button("Review confirmation window…") {
                            model.requestReview(
                                run: run,
                                sessionTitle: session.pageTitle ?? "Captured session"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Exact prompt and target are shown before anything is sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if run.status == .failed,
                          OpenCodeReviewTargeting.pinnedTargetID(run) != nil,
                          !run.promptPreview.isEmpty,
                          run.candidates.contains(where: { run.eligibleSessionIds.contains($0.sessionId) }) {
                    HStack {
                        Button("Review saved prompt for retry…") {
                            model.requestReview(
                                run: run,
                                sessionTitle: session.pageTitle ?? "Captured session"
                            )
                        }
                        Text("Only a clear OpenCode rejection can be retried; the relay revalidates the revision and target.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if run.status == .submitted {
                    Text("Sent to \(run.opencodeTitle ?? run.opencodeSessionId ?? "OpenCode") at \(Display.date(run.submittedAtMs)).")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                if run.status == .submitUnknown {
                    Text("Delivery is uncertain. Check OpenCode manually. The app and relay do not retry automatically.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                DisclosureGroup("Prompt preview (exact text)") {
                    ScrollView {
                        Text(run.promptPreview.isEmpty ? "No prompt was stored for this run." : run.promptPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }

                DisclosureGroup("Eligible sessions (\(run.eligibleSessionIds.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(run.candidates) { candidate in
                            HStack(alignment: .top, spacing: 8) {
                                Text(candidate.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(candidate.projectName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if run.eligibleSessionIds.contains(candidate.sessionId) {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(candidate.directory)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Directory: \(run.settings.directory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("No OpenCode suggestion for this capture yet.")
                    .foregroundStyle(.secondary)
                Button("Analyze eligible sessions") {
                    Task { await model.startOpenCodeRun(sessionId: session.sessionId) }
                }
                .disabled(model.isBusy("opencode-start") || !model.relay.isRunning)
                Text("Only existing OpenCode sessions in the configured exact directory are eligible. Nothing is sent until you confirm a native review window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
