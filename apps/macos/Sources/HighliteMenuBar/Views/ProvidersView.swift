import SwiftUI
import HighliteMenuBarCore

struct ProvidersView: View {
    @ObservedObject var model: AppModel
    @State private var editor: ProviderDraft?
    @State private var disconnectTarget: ProviderInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI providers")
                        .font(.title3.weight(.semibold))
                    Text("Provider settings are loopback-only. Saving does not verify credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editor = ProviderDraft(
                        isNew: true,
                        providerId: "",
                        hasStoredKey: false,
                        originalKind: .openai,
                        originalBaseUrl: "",
                        kind: .openai,
                        model: "",
                        baseUrl: "",
                        makeDefault: model.providers?.providers.isEmpty ?? true
                    )
                } label: {
                    Label("Add provider", systemImage: "plus")
                }
                Button {
                    Task { await model.refreshProviders() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(16)
            Divider()

            if model.providers?.enabled == false {
                EmptyHint(
                    title: "Provider management disabled",
                    detail: "The relay is not bound to loopback, so remote provider configuration is refused."
                )
                .padding()
                Spacer()
            } else if let providers = model.providers?.providers, !providers.isEmpty {
                List {
                    ForEach(providers) { provider in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(provider.id)
                                        .font(.headline)
                                    if model.providers?.defaultProvider == provider.id {
                                        StatusPill(text: "Default", color: .green)
                                    }
                                    if provider.hasApiKey {
                                        StatusPill(text: "Key stored", color: .blue)
                                    } else {
                                        StatusPill(text: "No key", color: .secondary)
                                    }
                                }
                                Text("\(provider.kind.displayName) · \(provider.model)")
                                    .font(.callout)
                                if !provider.baseUrl.isEmpty {
                                    Text(provider.baseUrl)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Text("Saved, not verified")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                editor = ProviderDraft(
                                    isNew: false,
                                    providerId: provider.id,
                                    hasStoredKey: provider.hasApiKey,
                                    originalKind: provider.kind,
                                    originalBaseUrl: provider.baseUrl,
                                    kind: provider.kind,
                                    model: provider.model,
                                    baseUrl: provider.baseUrl,
                                    makeDefault: model.providers?.defaultProvider == provider.id
                                )
                            }
                            if model.providers?.defaultProvider != provider.id {
                                Button("Make default") {
                                    Task { await model.makeProviderDefault(id: provider.id) }
                                }
                                .disabled(model.isBusy("provider-default"))
                            }
                            Button("Disconnect", role: .destructive) {
                                disconnectTarget = provider
                            }
                            .disabled(model.isBusy("provider-disconnect"))
                        }
                        .padding(.vertical, 5)
                    }
                }
            } else {
                EmptyHint(
                    title: "No providers configured",
                    detail: "Add an OpenAI, Anthropic, or OpenAI-compatible connection. Live Jira and OpenCode recipes need a default provider."
                )
                .padding()
                Spacer()
            }
        }
        .task {
            await model.refreshProviders()
        }
        .sheet(item: $editor) { draft in
            ProviderEditorView(model: model, draft: draft)
        }
        .alert(item: $disconnectTarget) { provider in
            Alert(
                title: Text("Disconnect \(provider.id)?"),
                message: Text("The stored API key for this provider is removed. This cannot be undone."),
                primaryButton: .destructive(Text("Disconnect")) {
                    Task { await model.disconnectProvider(id: provider.id) }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct ProviderDraft: Identifiable {
    let isNew: Bool
    let providerId: String
    let hasStoredKey: Bool
    let originalKind: ProviderKind
    let originalBaseUrl: String
    var kind: ProviderKind
    var model: String
    var baseUrl: String
    var makeDefault: Bool

    var id: String { isNew ? "new-provider" : providerId }
}

private struct ProviderEditorView: View {
    @ObservedObject var model: AppModel
    let draft: ProviderDraft
    @Environment(\.dismiss) private var dismiss
    @State private var providerId: String
    @State private var kind: ProviderKind
    @State private var modelName: String
    @State private var baseUrl: String
    @State private var apiKey = ""
    @State private var clearApiKey = false
    @State private var makeDefault: Bool
    @State private var saving = false
    @State private var errorText: String?

    private var canPreserveStoredKey: Bool {
        draft.hasStoredKey && ProviderCredentialPolicy.canPreserveStoredKey(
            originalKind: draft.originalKind,
            originalBaseURL: draft.originalBaseUrl,
            newKind: kind,
            newBaseURL: baseUrl
        )
    }

    private var explicitlyClearingKey: Bool {
        kind == .openaiCompatible && clearApiKey
    }

    private var requiresKeyReentry: Bool {
        draft.hasStoredKey && !canPreserveStoredKey && !explicitlyClearingKey
    }

    private var keyFieldTitle: String {
        if !draft.hasStoredKey {
            return "API key"
        }
        if explicitlyClearingKey {
            return "API key (ignored while removing the stored key)"
        }
        if canPreserveStoredKey {
            return "New API key (blank keeps existing for this kind and endpoint)"
        }
        return "API key required for changed kind or endpoint"
    }

    init(model: AppModel, draft: ProviderDraft) {
        self.model = model
        self.draft = draft
        _providerId = State(initialValue: draft.providerId)
        _kind = State(initialValue: draft.kind)
        _modelName = State(initialValue: draft.model)
        _baseUrl = State(initialValue: draft.baseUrl)
        _makeDefault = State(initialValue: draft.makeDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.isNew ? "Add AI provider" : "Edit \(draft.providerId)")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Provider ID", text: $providerId)
                    .disabled(!draft.isNew)
                Picker("Kind", selection: $kind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: kind) { _, newKind in
                    if newKind != .openaiCompatible {
                        baseUrl = ""
                    }
                }
                TextField("Model", text: $modelName)
                if kind == .openaiCompatible {
                    TextField("Base URL", text: $baseUrl)
                } else {
                    LabeledContent(
                        "Endpoint",
                        value: ProviderEndpointValidation.defaultBaseURL(for: kind)
                    )
                }
                SecureField(keyFieldTitle, text: $apiKey)
                if kind == .openaiCompatible, !draft.isNew, draft.hasStoredKey {
                    Toggle("Remove stored API key", isOn: $clearApiKey)
                }
                Toggle("Make default provider", isOn: $makeDefault)
            }
            .formStyle(.grouped)

            if draft.hasStoredKey {
                if canPreserveStoredKey {
                    Text("The stored API key is reused only for this unchanged kind and endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if explicitlyClearingKey {
                    Text("The stored API key will be removed. This cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Changing the provider kind or endpoint requires re-entering the API key. The old key will not be silently reused.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Credentials are saved by the relay in its private configuration and are never shown again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Task {
                        saving = true
                        errorText = nil
                        let error = await model.saveProvider(
                            id: providerId,
                            kind: kind,
                            model: modelName,
                            baseURL: baseUrl,
                            apiKey: apiKey,
                            clearApiKey: clearApiKey,
                            makeDefault: makeDefault
                        )
                        saving = false
                        if let error {
                            errorText = error
                        } else {
                            apiKey = ""
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    saving
                        || model.isBusy("provider-save")
                        || (requiresKeyReentry
                            && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}
