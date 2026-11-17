import SwiftUI
import HighliteMenuBarCore

struct ActivityView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                "Recipe activity",
                subtitle: "Metadata only: no drafts, prompts, candidate lists, or capture summaries."
            ) {
                HStack(spacing: 12) {
                    if let last = model.lastPollAt {
                        Text("Updated \(Display.relative(Int64(last.timeIntervalSince1970 * 1000)))")
                            .font(.caption)
                            .foregroundStyle(DashboardTheme.muted)
                    }
                    Button {
                        Task { await model.refreshActivity() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.relay.isRunning)
                }
            }
            .padding(.horizontal, DashboardStyle.pagePadding)
            .padding(.vertical, DashboardStyle.headerVerticalPadding)

            Divider()

            if let error = model.activityError {
                EmptyHint(
                    title: "Activity unavailable",
                    detail: error,
                    systemImage: "exclamationmark.triangle"
                )
                .padding(DashboardStyle.pagePadding)
            } else if model.activity.isEmpty {
                EmptyHint(
                    title: "No recipe activity",
                    detail: "Jira drafts and OpenCode suggestions appear here after a capture is processed.",
                    systemImage: "clock.arrow.circlepath"
                )
                .padding(DashboardStyle.pagePadding)
            } else {
                List(model.activity) { item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(item.recipe == "opencode" ? "OpenCode" : "Jira")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(DashboardTheme.neutralSoft, in: Capsule())
                                StatusPill(text: item.status, color: item.statusColor)
                                if let title = item.title {
                                    Text(title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(Display.relative(item.updatedAtMs))
                                    .font(.caption)
                                    .foregroundStyle(DashboardTheme.muted)
                            }
                            HStack(spacing: 12) {
                                Text(item.sessionId)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(DashboardTheme.muted)
                                if let issueKey = item.issueKey {
                                    Text("Jira \(issueKey)")
                                        .font(.caption)
                                }
                                if let title = item.opencodeTitle {
                                    Text("OpenCode \(title)")
                                        .font(.caption)
                                }
                            }
                            if let error = item.error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(DashboardTheme.danger)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Open") {
                            Task {
                                model.dashboardSection = .sessions
                                await model.selectSession(item.sessionId)
                            }
                        }
                        if item.recipe == "opencode", item.status == "suggested" {
                            Button("Review") {
                                Task {
                                    await model.selectSession(item.sessionId)
                                    if let run = model.openCodeRuns[item.sessionId] {
                                        model.requestReview(run: run, sessionTitle: item.title ?? "Pending suggestion")
                                    } else {
                                        await model.reviewNextPending()
                                    }
                                }
                            }
                            .buttonStyle(HighlitePrimaryButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
                .background(DashboardTheme.canvas)
            }
        }
        .background(DashboardTheme.canvas)
        .task {
            await model.refreshActivity()
        }
    }
}
