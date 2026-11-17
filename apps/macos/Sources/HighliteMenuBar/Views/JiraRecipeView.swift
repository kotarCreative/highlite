import SwiftUI
import HighliteMenuBarCore

struct JiraRecipeView: View {
    @ObservedObject var model: AppModel
    @State private var settings = JiraSettings.defaults()
    @State private var apiToken = ""
    @State private var extraFieldsText = "{}"
    @State private var initialized = false

    private var projectChoices: [JiraChoice] {
        model.jiraConnection?.projects ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    "Jira issue recipe",
                    subtitle: "Capture → AI draft → review → Jira. Connection tests and choices use the live Jira API."
                ) {
                    StatusPill(
                        text: settings.enabled ? "Enabled" : "Disabled",
                        color: settings.enabled ? DashboardTheme.success : DashboardTheme.muted
                    )
                }

                Form {
                    Section("Recipe") {
                        Toggle("Enable Jira drafts", isOn: $settings.enabled)
                        Toggle("Draft automatically after a capture", isOn: $settings.autoDraft)
                        Picker("Publication", selection: $settings.publishMode) {
                            ForEach(JiraPublishMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Toggle("Share capture images with the AI provider", isOn: $settings.includeImages)
                        Toggle("Attach selected capture images to Jira", isOn: $settings.attachImages)
                        Text("Off by default. When enabled, the AI may choose up to five allowlisted PNGs from the capture; Highlite uploads them to Jira after creating the issue. This is separate from sharing images with the AI provider.")
                            .font(.caption2)
                            .foregroundStyle(DashboardTheme.muted)
                    }

                    Section("Jira connection") {
                        TextField("Site URL", text: $settings.jira.siteUrl)
                        TextField("Account email", text: $settings.jira.email)
                        SecureField(
                            model.jiraConfig?.recipe.hasApiToken == true
                                ? "API token (blank keeps the saved token for this site and email)"
                                : "API token",
                            text: $apiToken
                        )
                        HStack {
                            Button("Test connection and load projects") {
                                Task { await testConnection() }
                            }
                            .disabled(model.isBusy("jira-connection"))
                            if model.isBusy("jira-connection") {
                                ProgressView().controlSize(.small)
                            }
                            if let name = model.jiraConnection?.displayName {
                                Text("Last test connected as \(name)")
                                    .font(.caption)
                                    .foregroundStyle(DashboardTheme.success)
                            }
                        }
                        Text("A blank token is omitted from requests. Discovery may use the saved token only when the site URL and email match.")
                            .font(.caption2)
                            .foregroundStyle(DashboardTheme.muted)
                    }

                    Section("Destination") {
                        if projectChoices.isEmpty {
                            TextField("Project key", text: $settings.jira.projectKey)
                            Text("Test the connection to load project choices.")
                                .font(.caption)
                                .foregroundStyle(DashboardTheme.muted)
                        } else {
                            Picker("Project", selection: Binding(
                                get: { settings.jira.projectKey },
                                set: { value in
                                    if settings.jira.projectKey != value {
                                        settings.jira.projectKey = value
                                        settings.jira.issueTypeId = ""
                                        model.jiraIssueTypes = []
                                    }
                                }
                            )) {
                                if !settings.jira.projectKey.isEmpty,
                                   !projectChoices.contains(where: { $0.value == settings.jira.projectKey }) {
                                    Text(settings.jira.projectKey).tag(settings.jira.projectKey)
                                }
                                ForEach(projectChoices) { project in
                                    Text("\(project.name) (\(project.value))").tag(project.value)
                                }
                            }
                        }

                        if model.jiraIssueTypes.isEmpty {
                            HStack {
                                TextField("Issue type ID", text: $settings.jira.issueTypeId)
                                Button("Load issue types") {
                                    Task { await loadIssueTypes() }
                                }
                                .disabled(
                                    settings.jira.projectKey.isEmpty || model.isBusy("jira-types")
                                )
                            }
                            Text("Issue types are fetched for the selected project.")
                                .font(.caption)
                                .foregroundStyle(DashboardTheme.muted)
                        } else {
                            Picker("Issue type", selection: $settings.jira.issueTypeId) {
                                if !settings.jira.issueTypeId.isEmpty,
                                   !model.jiraIssueTypes.contains(where: { $0.value == settings.jira.issueTypeId }) {
                                    Text("Current type (\(settings.jira.issueTypeId))")
                                        .tag(settings.jira.issueTypeId)
                                }
                                ForEach(model.jiraIssueTypes) { issueType in
                                    Text(issueType.name).tag(issueType.value)
                                }
                            }
                            Button("Reload issue types") {
                                Task { await loadIssueTypes() }
                            }
                            .disabled(model.isBusy("jira-types"))
                        }

                        Text("Extra fields JSON")
                            .font(.caption.weight(.semibold))
                        TextEditor(text: $extraFieldsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 80)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(DashboardTheme.lineStrong)
                            }
                        Text("Static Jira field mappings only. summary, description, project, and issuetype cannot be overridden.")
                            .font(.caption2)
                            .foregroundStyle(DashboardTheme.muted)
                    }

                    Section("AI instructions") {
                        TextEditor(text: $settings.prompt)
                            .font(.body)
                            .frame(minHeight: 140)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(DashboardTheme.lineStrong)
                            }
                        Text("Capture content is treated as untrusted evidence. Review every draft before publishing.")
                            .font(.caption)
                            .foregroundStyle(DashboardTheme.muted)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Button("Refresh settings") {
                        Task {
                            await model.refreshJiraConfig()
                            loadFromModel(force: true)
                        }
                    }
                    Spacer()
                    if model.isBusy("jira-save") {
                        ProgressView().controlSize(.small)
                    }
                    Button("Save Jira recipe") {
                        Task { await save() }
                    }
                    .buttonStyle(HighlitePrimaryButtonStyle())
                    .disabled(model.isBusy("jira-save"))
                }

                Card("Where credentials live") {
                    Text("The Jira API token is stored by the relay in its private plaintext configuration file. It is not migrated to Keychain. Only this app's relay bearer tokens use Keychain.")
                        .font(.caption)
                        .foregroundStyle(DashboardTheme.muted)
                }
            }
            .padding(DashboardStyle.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await model.refreshJiraConfig()
            loadFromModel(force: false)
        }
    }

    private func loadFromModel(force: Bool) {
        guard force || !initialized else { return }
        if let stored = model.jiraConfig?.recipe.settings {
            let normalized = JiraInputNormalization.settings(stored)
            settings = normalized
            extraFieldsText = (try? normalized.jira.extraFields.prettyString()) ?? "{}"
        } else {
            settings = .defaults()
            extraFieldsText = "{}"
        }
        initialized = true
    }

    private func save() async {
        var candidate = settings
        do {
            candidate.jira.extraFields = try JSONValue.parseObject(extraFieldsText)
        } catch {
            model.errorMessage = "Extra fields must be a valid JSON object."
            return
        }
        let ok = await model.saveJira(settings: candidate, apiToken: apiToken)
        if ok {
            apiToken = ""
            initialized = false
            loadFromModel(force: true)
        }
    }

    private func testConnection() async {
        let ok = await model.testJiraConnection(
            siteUrl: settings.jira.siteUrl,
            email: settings.jira.email,
            apiToken: apiToken,
            projectKey: settings.jira.projectKey
        )
        guard ok else { return }
        if settings.jira.projectKey.isEmpty,
           let first = model.jiraConnection?.projects.first {
            settings.jira.projectKey = first.value
        }
        if !settings.jira.projectKey.isEmpty {
            await loadIssueTypes()
        }
    }

    private func loadIssueTypes() async {
        guard !settings.jira.projectKey.isEmpty else { return }
        _ = await model.loadJiraIssueTypes(
            siteUrl: settings.jira.siteUrl,
            email: settings.jira.email,
            apiToken: apiToken,
            projectKey: settings.jira.projectKey
        )
        if settings.jira.issueTypeId.isEmpty,
           let first = model.jiraIssueTypes.first {
            settings.jira.issueTypeId = first.value
        }
    }
}
