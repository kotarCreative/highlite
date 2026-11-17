import SwiftUI
import HighliteMenuBarCore

struct OverviewView: View {
    @ObservedObject var model: AppModel
    @State private var embedAssetPath = SiteEmbedSnippet.defaultAssetPath

    private var embedScript: String? {
        guard let ingestToken = model.ingestToken else { return nil }
        return try? SiteEmbedSnippet(
            assetPath: embedAssetPath,
            relayBaseURL: model.relay.baseURL,
            ingestToken: ingestToken
        ).html
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DashboardStyle.sectionSpacing) {
                PageHeader(
                    "Highlite",
                    subtitle: "Local capture relay and reviewed AI recipes"
                ) {
                    StatusPill(text: model.relay.phase.label, color: model.relay.phase.color)
                }

                Card("Relay", icon: "bolt") {
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

                    HStack(spacing: DashboardStyle.controlSpacing) {
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

                Card("Site embed", icon: "chevron.left.forwardslash.chevron.right") {
                    Text("Add a script tag that sends captures from your site to this relay.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("SDK asset path")
                            .font(.caption.weight(.semibold))
                        HStack(spacing: DashboardStyle.controlSpacing) {
                            TextField("SDK asset path", text: $embedAssetPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 220, maxWidth: 360)
                            CopyButton(
                                title: "Copy embed script",
                                value: embedScript,
                                help: "Copies a script-tag snippet for this relay URL and ingest token."
                            )
                            Spacer(minLength: 0)
                        }
                        Text("Serve packages/sdk/dist/highlite.iife.js at this path, or use a full asset URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let embedScript {
                        DisclosureGroup {
                            CodeBlock(text: embedScript)
                                .padding(.top, 4)
                        } label: {
                            Text("Preview script")
                                .font(.caption.weight(.semibold))
                        }
                    } else if model.ingestToken == nil {
                        Label(
                            "Start the relay to create the ingest token used by the embed script.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Label("Enter a valid SDK asset path or URL.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Label(
                        "The ingest token is visible to the browser. Add this site's exact origin in Settings before capturing.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: DashboardStyle.sectionSpacing) {
                    Card("Pending review", icon: "tray.full") {
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

                    Card("Setup", icon: "slider.horizontal.3") {
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

                Card("Privacy and targeting", icon: "lock.shield") {
                    Text(
                        "Highlite never looks at the focused application. OpenCode routing uses only bounded capture text and candidate session metadata, then waits for your confirmation in a native window."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text("Provider and Jira credentials stay in the relay's private files. Only relay bearer tokens are stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card("Relay log", icon: "text.alignleft") {
                    if model.relayLogs.isEmpty {
                        Text("No relay output captured yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        CodeBlock(
                            text: model.relayLogs.suffix(80).joined(separator: "\n"),
                            scrolls: true,
                            minHeight: 150,
                            maxHeight: 150
                        )
                    }
                }
            }
            .padding(DashboardStyle.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if model.relay.isRunning, model.sessions.isEmpty {
                await model.refreshAll()
            }
        }
    }
}
