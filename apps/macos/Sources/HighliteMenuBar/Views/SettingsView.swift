import AppKit
import SwiftUI
import HighliteMenuBarCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var portText = "8787"
    @State private var origins = ""
    @State private var binaryPath = ""
    @State private var loaded = false
    @State private var applying = false

    private let paths = RelayPaths.standard()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.title3.weight(.semibold))
                    Text("The relay listens on loopback. Existing relay tokens and unrelated env settings are preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Form {
                    Section("Local relay") {
                        TextField("Local port", text: $portText)
                        TextField("Allowed browser origins", text: $origins)
                        Text("Comma-separated origins, for example https://app.example.com. The native app itself does not need an Origin entry. Leave blank to remove the allowlist entry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Relay binary (optional)", text: $binaryPath)
                            Button("Choose…") { chooseBinary() }
                        }
                        Text("Resolution order: this path, HIGHLITE_RELAY_BIN, the bundled Contents/Resources/highlite-relay, then target/release/highlite-relay.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Relay state") {
                        LabeledContent("Status", value: model.relay.phase.label)
                        LabeledContent("Endpoint", value: model.relay.baseURL.absoluteString)
                        LabeledContent(
                            "Ownership",
                            value: model.relay.owned
                                ? "Managed by HighliteMenuBar"
                                : (model.relay.isRunning ? "External relay (never stopped by this app)" : "None")
                        )
                        if let version = model.relay.relayVersion {
                            LabeledContent("Relay compiler", value: version)
                        }
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Spacer()
                    if applying || model.isBusy("settings") {
                        ProgressView().controlSize(.small)
                    }
                    Button("Save and restart relay") {
                        Task { await apply() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || model.isBusy("settings"))
                }

                Card("Private paths") {
                    pathRow("Application support", value: paths.supportDirectory.path)
                    pathRow("Environment file (0600)", value: paths.envFile.path)
                    pathRow("Relay config directory (0700)", value: paths.configDirectory.path)
                    pathRow("Relay data directory", value: paths.dataDirectory.path)
                    Text("Provider and Jira credentials are the relay's existing private files in the config directory. This app does not read them and does not claim Keychain protection for them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card("Relay tokens") {
                    Text("Read and ingest bearer tokens are generated once, stored in Keychain, and mirrored into the private relay environment file. They are never logged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        CopyButton(title: "Copy read token", value: model.readToken)
                        CopyButton(title: "Copy ingest token", value: model.ingestToken)
                        CopyButton(title: "Copy relay URL", value: model.relay.baseURL.absoluteString)
                    }
                    Text(model.readToken == nil ? "Tokens will appear after the relay starts." : "Tokens are loaded for this session.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Card("Suggestion popup history") {
                    Text("Deferring a suggestion persists its review key so the same revision does not interrupt you again. Clear this history to allow notifications for still-pending runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear popup and defer history") {
                        model.clearNotificationHistory()
                    }
                    Text("This does not submit, dismiss, or delete any relay run.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if !loaded {
                portText = String(model.settings.port)
                origins = model.settings.allowedOrigins
                binaryPath = model.settings.relayBinaryPath
                loaded = true
            }
        }
    }

    @ViewBuilder
    private func pathRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 190, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            if FileManager.default.fileExists(atPath: value) {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: value)])
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Relay Binary"
        if panel.runModal() == .OK, let url = panel.url {
            binaryPath = url.standardizedFileURL.path
        }
    }

    private func apply() async {
        applying = true
        let ok = await model.applySettings(
            portText: portText,
            origins: origins,
            binaryPath: binaryPath
        )
        if ok {
            binaryPath = model.settings.relayBinaryPath
            origins = model.settings.allowedOrigins
            portText = String(model.settings.port)
        }
        applying = false
    }
}
