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
            PageHeader(
                "Captured sessions",
                subtitle: "Review captures, Jira drafts, and OpenCode suggestions."
            ) {
                Button {
                    Task { await model.refreshSessions() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.relay.isRunning)
            }
            .padding(.horizontal, DashboardStyle.pagePadding)
            .padding(.vertical, DashboardStyle.headerVerticalPadding)

            Divider()

            if model.sessions.isEmpty {
                EmptyHint(
                    title: "No captures yet",
                    detail: "Upload a browser capture to the relay. Sessions appear here after compilation.",
                    systemImage: "rectangle.stack"
                )
                .padding(DashboardStyle.pagePadding)
                Spacer()
            } else {
                HSplitView {
                    List(model.sessions, selection: selection) { session in
                        SessionRow(session: session)
                            .tag(session.sessionId)
                    }
                    .frame(
                        minWidth: 250,
                        idealWidth: 290,
                        maxWidth: 380,
                        maxHeight: .infinity
                    )
                    .scrollContentBackground(.hidden)
                    .background(DashboardTheme.canvas)

                    if let selected = model.selectedSession {
                        SessionDetailView(model: model, session: selected)
                            .frame(minWidth: 480, maxHeight: .infinity)
                    } else {
                        EmptyHint(
                            title: "Select a session",
                            detail: "Open a capture to review Jira drafts and OpenCode suggestions.",
                            systemImage: "sidebar.left"
                        )
                        .frame(minWidth: 480, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundStyle(DashboardTheme.muted)
            if let url = session.pageUrl, !url.isEmpty {
                Text(url)
                    .font(.caption2)
                    .foregroundStyle(DashboardTheme.muted)
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
                            .foregroundStyle(DashboardTheme.muted)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 14) {
                        Text("Received \(Display.date(session.receivedAtMs))")
                        Text(Display.bytes(session.bytes))
                        Text("Duration \(Display.duration(session.durationMs))")
                    }
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
                }

                if let error = session.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(DashboardTheme.danger)
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
            .padding(DashboardStyle.pagePadding)
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
    @State private var attachments: Set<String> = []
    @State private var syncedRevision = -1
    @State private var syncedUpdatedAt: Int64 = -1

    private var run: JiraRun? { model.jiraRuns[session.sessionId] }

    private var draftIsDirty: Bool {
        guard let draft = run?.draft else { return false }
        return summary != draft.summary
            || description != draft.description
            || attachments != Set(draft.attachments)
    }

    var body: some View {
        Card("Jira issue") {
            if let run {
                HStack {
                    StatusPill(text: run.status.label, color: run.status.color)
                    Text("Revision \(run.revision)")
                        .font(.caption)
                        .foregroundStyle(DashboardTheme.muted)
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
                        .foregroundStyle(DashboardTheme.danger)
                        .textSelection(.enabled)
                }

                if run.status == .queued || run.status == .analyzing || run.status == .publishing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(run.status == .publishing ? "Publishing to Jira..." : "Generating a draft from the capture...")
                            .foregroundStyle(DashboardTheme.muted)
                    }
                }

                if let provider = run.provider {
                    Text("\(provider.id) · \(provider.model)")
                        .font(.caption)
                        .foregroundStyle(DashboardTheme.muted)
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
                                    .strokeBorder(DashboardTheme.lineStrong)
                            }

                        if !run.availableAttachments.isEmpty {
                            Text("Jira attachments")
                                .font(.caption.weight(.semibold))
                            ForEach(run.availableAttachments) { choice in
                                Toggle(choice.name, isOn: attachmentBinding(choice.id))
                                    .disabled(run.status != .draft)
                            }
                            Text("Selected PNGs are uploaded only after the issue is created. Deselect any image you do not want to share.")
                                .font(.caption2)
                                .foregroundStyle(DashboardTheme.muted)
                        }
                    }

                    if !run.attachmentResults.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(run.attachmentResults) { result in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(result.name)
                                        .font(.caption.weight(.medium))
                                    Text(result.status.label)
                                        .font(.caption2)
                                        .foregroundStyle(result.status.color)
                                    if let error = result.error {
                                        Text(error)
                                            .font(.caption2)
                                            .foregroundStyle(DashboardTheme.danger)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        Button("Save draft") {
                            Task {
                                _ = await model.saveJiraDraft(
                                    sessionId: session.sessionId,
                                    revision: run.revision,
                                    draft: JiraDraft(
                                        summary: summary,
                                        description: description,
                                        attachments: run.availableAttachments
                                            .map(\.id)
                                            .filter(attachments.contains)
                                    )
                                )
                            }
                        }
                        .buttonStyle(HighlitePrimaryButtonStyle())
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
                            .foregroundStyle(draftIsDirty ? DashboardTheme.warning : DashboardTheme.muted)
                    }
                    if let draft = run.draft {
                        Text("Draft loaded: \(draft.summary.count) summary characters, \(draft.description.count) description characters.")
                            .font(.caption2)
                            .foregroundStyle(DashboardTheme.muted)
                    }
                }

                if run.status == .published, let issueKey = run.issueKey {
                    Text("Published \(issueKey)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(DashboardTheme.success)
                }
                if run.status == .publishUnknown {
                    Text("Publication is uncertain. Check Jira for the issue before trying again; the relay will not retry automatically.")
                        .font(.callout)
                        .foregroundStyle(DashboardTheme.danger)
                }

                if run.status == .draft, let draft = run.draft {
                    Text("Draft preview: \(draft.summary)")
                        .font(.caption)
                        .foregroundStyle(DashboardTheme.muted)
                        .lineLimit(1)
                }
            } else {
                Text("No Jira draft for this capture yet.")
                    .foregroundStyle(DashboardTheme.muted)
                Button("Generate Jira draft") {
                    Task { await model.startJiraDraft(sessionId: session.sessionId) }
                }
                .buttonStyle(HighlitePrimaryButtonStyle())
                .disabled(model.isBusy("jira-start") || !model.relay.isRunning)
                Text("Configure the Jira recipe and a default AI provider first. Draft generation is reviewed before publication.")
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
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
            Text("This creates a Jira issue in \(run?.settings.jira.projectKey ?? "the configured project").\(run?.draft?.attachments.isEmpty == false ? " Selected capture images are uploaded after the issue is created." : "")")
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
            attachments = Set(draft.attachments)
        }
    }

    private func attachmentBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { attachments.contains(id) },
            set: { selected in
                if selected {
                    attachments.insert(id)
                } else {
                    attachments.remove(id)
                }
            }
        )
    }
}

private extension JiraAttachmentStatus {
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .uploaded: return "Uploaded"
        case .failed: return "Not uploaded"
        case .unknown: return "Unconfirmed"
        }
    }

    var color: Color {
        switch self {
        case .pending: return DashboardTheme.muted
        case .uploaded: return DashboardTheme.success
        case .failed: return DashboardTheme.danger
        case .unknown: return DashboardTheme.warning
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
                        .foregroundStyle(DashboardTheme.muted)
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
                        .foregroundStyle(DashboardTheme.warning)
                }
                if run.status == .submitted || run.status == .submitUnknown {
                    Text("This run is terminal and cannot be analyzed again, even if recipe settings change. It remains as the delivery record.")
                        .font(.caption)
                        .foregroundStyle(DashboardTheme.muted)
                }

                if let error = run.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(DashboardTheme.danger)
                        .textSelection(.enabled)
                }

                if run.status == .queued || run.status == .analyzing || run.status == .submitting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(run.status == .submitting ? "Submitting after confirmation..." : "Ranking eligible sessions from bounded metadata...")
                            .foregroundStyle(DashboardTheme.muted)
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
                                color: suggestion.confidence == .high ? DashboardTheme.success : (suggestion.confidence == .medium ? DashboardTheme.warning : DashboardTheme.muted)
                            )
                        }
                        Text(suggestion.directory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DashboardTheme.muted)
                            .textSelection(.enabled)
                        Text(suggestion.reason)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                } else if run.status == .suggested {
                    Text("No AI target was selected. Choose any eligible session manually in the confirmation window.")
                        .font(.callout)
                        .foregroundStyle(DashboardTheme.muted)
                }

                if let target = run.opencodeTitle ?? run.suggestion?.title {
                    Text("Current target: \(target)")
                        .font(.caption)
                        .foregroundStyle(DashboardTheme.muted)
                }

                if run.status == .suggested {
                    HStack {
                        Button("Review confirmation window…") {
                            model.requestReview(
                                run: run,
                                sessionTitle: session.pageTitle ?? "Captured session"
                            )
                        }
                        .buttonStyle(HighlitePrimaryButtonStyle())
                        Text("Exact prompt and target are shown before anything is sent.")
                            .font(.caption)
                            .foregroundStyle(DashboardTheme.muted)
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
                            .foregroundStyle(DashboardTheme.muted)
                    }
                }

                if run.status == .submitted {
                    Text("Sent to \(run.opencodeTitle ?? run.opencodeSessionId ?? "OpenCode") at \(Display.date(run.submittedAtMs)).")
                        .font(.callout)
                        .foregroundStyle(DashboardTheme.success)
                }
                if run.status == .submitUnknown {
                    Text("Delivery is uncertain. Check OpenCode manually. The app and relay do not retry automatically.")
                        .font(.callout)
                        .foregroundStyle(DashboardTheme.danger)
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
                                    .foregroundStyle(DashboardTheme.muted)
                                Spacer()
                                if run.eligibleSessionIds.contains(candidate.sessionId) {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(DashboardTheme.success)
                                }
                            }
                            Text(candidate.directory)
                                .font(.caption2)
                                .foregroundStyle(DashboardTheme.muted)
                        }
                    }
                }

                Text("Directory: \(run.settings.directory)")
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
                    .textSelection(.enabled)
            } else {
                Text("No OpenCode suggestion for this capture yet.")
                    .foregroundStyle(DashboardTheme.muted)
                Button("Analyze eligible sessions") {
                    Task { await model.startOpenCodeRun(sessionId: session.sessionId) }
                }
                .buttonStyle(HighlitePrimaryButtonStyle())
                .disabled(model.isBusy("opencode-start") || !model.relay.isRunning)
                Text("Only existing OpenCode sessions in the configured exact directory are eligible. Nothing is sent until you confirm a native review window.")
                    .font(.caption)
                    .foregroundStyle(DashboardTheme.muted)
            }
        }
    }
}
