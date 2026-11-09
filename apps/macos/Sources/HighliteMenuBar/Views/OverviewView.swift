import SwiftUI
import HighliteMenuBarCore

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Highlite")
                            .font(.system(size: 30, weight: .semibold))
                        Text("Local capture relay and reviewed AI recipes")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(text: model.relay.phase.label, color: model.relay.phase.color)
                }

                Card("Relay") {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.relay.detail)
                                .font(.callout)
                                .textSelection(.enabled)
                            if let version = model.relay.relayVersion {
                                Text("Compiler \(version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(model.relay.baseURL.absoluteString)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text(model.relay.owned ? "Managed by this app" : "External or stopped relay")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            switch model.relay.phase {
                            case .running:
                                Button("Stop relay") {
                                    Task { await model.stopRelay() }
                                }
                            case .checking, .starting:
                                Button("Cancel relay start") {
                                    Task { await model.stopRelay() }
                                }
                            case .stopping:
                                Button("Stopping relay…") {}
                                    .disabled(true)
                            case .stopped, .failed:
                                Button("Start relay") {
                                    Task { await model.startRelay() }
                                }
                                .disabled(model.isBusy("relay"))
                            }
                            Button("Refresh") {
                                Task { await model.refreshAll() }
                            }
                            .disabled(!model.relay.isRunning)
                        }
                    }

                    HStack(spacing: 10) {
                        CopyButton(title: "Copy relay URL", value: model.relay.baseURL.absoluteString)
                        CopyButton(
                            title: "Copy ingest token",
                            value: model.ingestToken,
                            help: "Use this token in the browser SDK upload configuration."
                        )
                        CopyButton(
                            title: "Copy read token",
                            value: model.readToken,
                            help: "Used by local integrations. Keep it private."
                        )
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    Card("Pending review") {
                        Text("\(model.pendingCount)")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                        Text(
                            model.pendingCount == 0
                                ? "No OpenCode suggestions are waiting."
                                : "Suggestions remain in the relay until you confirm or defer them."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Button("Review next pending") {
                            Task { await model.reviewNextPending() }
                        }
                        .disabled(model.pendingCount == 0)
                        Text("Nothing is sent automatically. Deferring only hides the popup for that revision.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Card("Setup") {
                        LabeledContent("Captures", value: "\(model.sessions.count)")
                        LabeledContent(
                            "Providers",
                            value: model.providers.flatMap { $0.defaultProvider }.map { "default: \($0)" } ?? "none configured"
                        )
                        LabeledContent(
                            "Jira recipe",
                            value: (model.jiraConfig?.recipe.settings?.enabled ?? false) ? "enabled" : "not enabled"
                        )
                        LabeledContent(
                            "OpenCode recipe",
                            value: (model.openCodeConfig?.recipe.settings?.enabled ?? false) ? "enabled" : "not enabled"
                        )
                        HStack {
                            Button("Providers") { model.dashboardSection = .providers }
                            Button("Jira") { model.dashboardSection = .jira }
                            Button("OpenCode") { model.dashboardSection = .openCode }
                        }
                    }
                }

                Card("Privacy and targeting") {
                    Text(
                        "Highlite never looks at the focused application. OpenCode routing uses only bounded capture text and candidate session metadata, then waits for your confirmation in a native window."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("Provider and Jira credentials stay in the relay's private files. Only relay bearer tokens are stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card("Relay log") {
                    if model.relayLogs.isEmpty {
                        Text("No relay output captured yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(model.relayLogs.suffix(80).joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 150)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if model.relay.isRunning, model.sessions.isEmpty {
                await model.refreshAll()
            }
        }
    }
}
