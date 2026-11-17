import AppKit
import SwiftUI
import HighliteMenuBarCore

struct OpenCodeRecipeView: View {
    @ObservedObject var model: AppModel
    @State private var settings = OpenCodeSettings()
    @State private var initialized = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    "OpenCode session recipe",
                    subtitle: "Suggests an existing OpenCode session. It never creates a session or sends a prompt automatically."
                ) {
                    StatusPill(
                        text: settings.enabled ? "Enabled" : "Disabled",
                        color: settings.enabled ? DashboardTheme.success : DashboardTheme.muted
                    )
                }

                Form {
                    Section("Recipe") {
                        Toggle("Enable OpenCode suggestions", isOn: $settings.enabled)
                        Toggle("Draft automatically after a capture", isOn: $settings.autoDraft)
                        Stepper(value: $settings.maxCandidates, in: 5...50) {
                            Text("Rank up to \(settings.maxCandidates) candidate sessions")
                        }
                    }

                    Section("Project directory") {
                        HStack {
                            TextField("Absolute project directory", text: $settings.directory)
                            Button("Choose…") {
                                chooseDirectory()
                            }
                        }
                        Text("Required when enabled. Only OpenCode sessions whose location.directory exactly equals this path are eligible. Subtrees are not included.")
                            .font(.caption)
                            .foregroundStyle(DashboardTheme.muted)
                    }

                    Section("OpenCode CLI") {
                        HStack {
                            TextField("CLI path (optional)", text: Binding(
                                get: { settings.opencodePath ?? "" },
                                set: { settings.opencodePath = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                            ))
                            Button("Choose…") {
                                chooseCLI()
                            }
                            Button("Validate CLI") {
                                Task {
                                    _ = await model.validateOpenCodeCLI(
                                        path: settings.opencodePath ?? "",
                                        directory: settings.directory
                                    )
                                }
                            }
                            .disabled(model.isBusy("opencode-cli"))
                        }
                        Text("Resolution order: this path, HIGHLITE_OPENCODE_BIN, then opencode on an augmented PATH that includes /opt/homebrew/bin, /usr/local/bin, and ~/.opencode/bin.")
                            .font(.caption)
                            .foregroundStyle(DashboardTheme.muted)
                        if let message = model.cliValidationMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(message.contains("responded") ? DashboardTheme.success : DashboardTheme.danger)
                                .textSelection(.enabled)
                        }
                        Text("The local check runs `opencode api server.info` with no shell. The relay separately invokes the authenticated CLI for discovery and submission.")
                            .font(.caption2)
                            .foregroundStyle(DashboardTheme.muted)
                    }

                    Section("Instructions") {
                        TextEditor(text: $settings.prompt)
                            .font(.body)
                            .frame(minHeight: 140)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(DashboardTheme.lineStrong)
                            }
                        Text("AI routing receives only the first 4 KiB of the capture summary plus candidate ID, title, directory, project, and timestamps. Capture content is untrusted evidence, not instructions.")
                            .font(.caption)
                            .foregroundStyle(DashboardTheme.muted)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Button("Refresh settings") {
                        Task {
                            await model.refreshOpenCodeConfig()
                            loadFromModel(force: true)
                        }
                    }
                    Spacer()
                    if model.isBusy("opencode-save") || model.isBusy("opencode-discover") {
                        ProgressView().controlSize(.small)
                    }
                    Button("Save settings") {
                        Task {
                            _ = await model.saveOpenCode(settings: settings)
                        }
                    }
                    .disabled(model.isBusy("opencode-save"))
                    Button("Save and discover") {
                        Task {
                            let ok = await model.saveOpenCode(settings: settings)
                            if ok {
                                _ = await model.discoverOpenCode(path: settings.opencodePath ?? "")
                            }
                        }
                    }
                    .buttonStyle(HighlitePrimaryButtonStyle())
                    .disabled(model.isBusy("opencode-save") || model.isBusy("opencode-discover"))
                }

                if let discovery = model.discovery {
                    Card("Discovery result") {
                        LabeledContent("OpenCode", value: discovery.opencode.version)
                        LabeledContent("Exact directory", value: discovery.directory)
                        LabeledContent("Eligible sessions", value: "\(discovery.sessions.count)")
                        LabeledContent("Projects", value: "\(discovery.projects.count)")

                        if discovery.sessions.isEmpty {
                            Text("No eligible root sessions were found for this exact directory.")
                                .font(.callout)
                                .foregroundStyle(DashboardTheme.muted)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(discovery.sessions) { session in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(session.title)
                                                .font(.callout.weight(.medium))
                                            Text(session.projectName)
                                                .font(.caption)
                                                .foregroundStyle(DashboardTheme.muted)
                                            Spacer()
                                            Text("Updated \(Display.relative(session.updatedAtMs))")
                                                .font(.caption2)
                                                .foregroundStyle(DashboardTheme.muted)
                                        }
                                        Text(session.directory)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(DashboardTheme.muted)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        if !discovery.projects.isEmpty {
                            DisclosureGroup("Projects") {
                                ForEach(discovery.projects) { project in
                                    HStack {
                                        Text(project.name)
                                        Spacer()
                                        Text(project.canonical)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(DashboardTheme.muted)
                                    }
                                }
                            }
                        }
                    }
                }

                Card("Review is mandatory") {
                    Text("A suggested run opens a native confirmation window with the exact prompt and a target chooser. Nothing is submitted until you press the send button there. Deferring leaves the run pending in the relay and the menu bar badge.")
                        .font(.callout)
                        .foregroundStyle(DashboardTheme.muted)
                }
            }
            .padding(DashboardStyle.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await model.refreshOpenCodeConfig()
            loadFromModel(force: false)
        }
    }

    private func loadFromModel(force: Bool) {
        guard force || !initialized else { return }
        settings = model.openCodeConfig?.recipe.settings ?? OpenCodeSettings()
        initialized = true
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Project Directory"
        if panel.runModal() == .OK, let url = panel.url {
            settings.directory = url.standardizedFileURL.path
        }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use OpenCode CLI"
        if panel.runModal() == .OK, let url = panel.url {
            settings.opencodePath = url.standardizedFileURL.path
        }
    }
}
