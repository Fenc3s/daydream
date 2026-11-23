import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    let appModel: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: selectionBinding) { section in
                Label(section.rawValue, systemImage: iconName(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
            .listStyle(.sidebar)
        } detail: {
            switch appModel.selectedSettingsSection {
            case .general:
                GeneralSettingsView(appModel: appModel)
            case .memory:
                MemorySettingsView(appModel: appModel)
            case .clipboardHistory:
                ClipboardHistorySettingsView(appModel: appModel)
            case .inputSources:
                InputSourceSettingsView(appModel: appModel)
            case .commands:
                CommandsSettingsView(appModel: appModel)
            case .versionHistory:
                VersionHistorySettingsView(appModel: appModel)
            }
        }
        .background(SettingsWindowConfigurator())
        .onAppear {
            appModel.updateWindowLifecycle(named: "Settings", isVisible: true)
        }
        .onDisappear {
            appModel.updateWindowLifecycle(named: "Settings", isVisible: false)
        }
    }

    private var selectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { appModel.selectedSettingsSection },
            set: { newValue in
                appModel.selectedSettingsSection = newValue ?? .general
            }
        )
    }

    private func iconName(for section: SettingsSection) -> String {
        switch section {
        case .general:
            return "gearshape"
        case .memory:
            return "brain"
        case .clipboardHistory:
            return "clipboard"
        case .inputSources:
            return "keyboard"
        case .commands:
            return "command"
        case .versionHistory:
            return "clock.arrow.circlepath"
        }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SettingsWindowConfigurationView)?.configureWindow()
    }
}

private final class SettingsWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }

        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
    }
}

private struct VersionHistorySettingsView: View {
    let appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    Text("Version History")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))

                    Spacer()

                    Button("Refresh") {
                        Task {
                            await appModel.refreshDiagnostics()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                settingsSection(title: "Application") {
                    settingsGroup {
                        settingsRow("Version") {
                            Text(appModel.applicationVersionDisplay)
                                .textSelection(.enabled)
                        }

                        if appModel.diagnostics.gitVersion.isAvailable {
                            Divider()

                            settingsRow("Git Commit") {
                                Text(appModel.diagnostics.gitVersion.shortCommitHash)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }

                            Divider()

                            settingsRow("Branch") {
                                Text(appModel.diagnostics.gitVersion.branch)
                                    .textSelection(.enabled)
                            }

                            Divider()

                            settingsRow("Repository") {
                                Text(appModel.diagnostics.gitVersion.repositoryPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Divider()

                            Text(appModel.diagnostics.gitVersion.availabilityMessage.isEmpty
                                ? "Git metadata is unavailable."
                                : appModel.diagnostics.gitVersion.availabilityMessage)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                        }
                    }
                }

                settingsSection(title: "Git Commit History") {
                    settingsGroup {
                        if appModel.diagnostics.gitCommitHistory.isEmpty {
                            Text("No Git commit history is available.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                        } else {
                            ForEach(appModel.diagnostics.gitCommitHistory, id: \.self) { commit in
                                Text(commit)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.vertical, 5)
                            }
                        }
                    }
                }

                settingsSection(title: "Actions") {
                    settingsGroup {
                        HStack(spacing: 10) {
                            Button("Reveal Repository") {
                                appModel.revealRepository()
                            }
                            .disabled(!appModel.diagnostics.gitVersion.isAvailable)

                            Button("Reveal Version Log") {
                                appModel.revealVersionLogFile()
                            }

                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .task {
            await appModel.refreshDiagnostics()
        }
    }
}

private struct GeneralSettingsView: View {
    let appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection(title: "Model & Endpoint") {
                    settingsGroup {
                        settingsRow("Provider") {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { appModel.settings.provider },
                                    set: { appModel.selectProvider($0) }
                                )
                            ) {
                                ForEach(AIProvider.allCases) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 240, alignment: .leading)
                        }

                        Divider()

                        switch appModel.settings.provider {
                        case .openRouter:
                            settingsRow("OpenRouter URL") {
                                TextField(
                                    "",
                                    text: Binding(
                                        get: { appModel.settings.openRouterBaseURL },
                                        set: {
                                            appModel.settings.openRouterBaseURL = $0
                                            appModel.saveSettings()
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                            Divider()

                            settingsRow("OpenRouter API Key") {
                                SecureField(
                                    "",
                                    text: Binding(
                                        get: { appModel.settings.openRouterAPIKey },
                                        set: {
                                            appModel.settings.openRouterAPIKey = $0
                                            appModel.saveSettings()
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                        case .deepSeek:
                            settingsRow("DeepSeek URL") {
                                TextField(
                                    "",
                                    text: Binding(
                                        get: { appModel.settings.deepSeekBaseURL },
                                        set: {
                                            appModel.settings.deepSeekBaseURL = $0
                                            appModel.saveSettings()
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                            Divider()

                            settingsRow("DeepSeek API Key") {
                                SecureField(
                                    "",
                                    text: Binding(
                                        get: { appModel.settings.deepSeekAPIKey },
                                        set: {
                                            appModel.settings.deepSeekAPIKey = $0
                                            appModel.saveSettings()
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                        case .chatGPT:
                            settingsRow("ChatGPT Account") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if appModel.isSigningInWithChatGPT {
                                        HStack(spacing: 10) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Waiting for browser sign-in…")
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button("Cancel") {
                                                appModel.cancelChatGPTSignIn()
                                            }
                                        }
                                    } else if let session = appModel.chatGPTAuthSession {
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(session.hasDirectPlanUsageScope ? .green : .orange)
                                                .frame(width: 8, height: 8)
                                            Text("Signed in as \(session.displayIdentity)")
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Button("Sign Out") {
                                                appModel.signOutOfChatGPT()
                                            }
                                        }

                                        Text("Uses your ChatGPT plan via Sign in with ChatGPT (OAuth + PKCE). Tokens refresh automatically.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Button("Sign in with ChatGPT") {
                                            appModel.signInWithChatGPT()
                                        }
                                        .buttonStyle(.borderedProminent)

                                        Text("Authenticate in your browser to use your ChatGPT Plus or Pro plan without an API key.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if let statusMessage = appModel.chatGPTAuthStatusMessage,
                                       !statusMessage.isEmpty {
                                        Text(statusMessage)
                                            .font(.caption)
                                            .foregroundStyle(
                                                appModel.chatGPTAuthSession == nil && !appModel.isSigningInWithChatGPT
                                                    ? .red
                                                    : .secondary
                                            )
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        Divider()

                        settingsRow("Default Model") {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { appModel.settings.defaultModel },
                                    set: { selectedModel in
                                        appModel.settings.setDefaultModel(selectedModel, for: appModel.settings.provider)
                                        appModel.saveSettings()
                                    }
                                )
                            ) {
                                ForEach(availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: 420, alignment: .leading)
                        }

                        Divider()

                        settingsRow("Default Reasoning") {
                            VStack(alignment: .leading, spacing: 6) {
                                Picker("", selection: Binding(
                                    get: { appModel.defaultReasoningMode(for: appModel.settings.defaultModel) },
                                    set: { appModel.selectDefaultReasoning($0) }
                                )) {
                                    ForEach(appModel.availableReasoningModes(for: appModel.settings.defaultModel)) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                Text("Saved separately for the selected default model. Used by commands that use default reasoning.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                settingsSection(title: "\(appModel.settings.provider.displayName) Models") {
                    ProviderModelCatalogEditor(
                        appModel: appModel,
                        provider: appModel.settings.provider
                    )
                    .id(appModel.settings.provider)
                }

                settingsSection(title: "Permissions") {
                    settingsGroup {
                        settingsRow("Accessibility") {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(appModel.diagnostics.accessibilityTrusted ? .green : .orange)
                                    .frame(width: 8, height: 8)
                                Text(appModel.diagnostics.accessibilityTrusted ? "Granted" : "Required")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Button("Request Access") {
                                appModel.promptForAccessibilityPermission()
                            }

                            Button("Open Settings") {
                                appModel.openAccessibilitySettings()
                            }

                            Spacer()
                        }

                        Divider()

                        settingsRow("iCloud Passwords for Browsers") {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(
                                    "Enable verification automation",
                                    isOn: Binding(
                                        get: { appModel.settings.iCloudPasswordsDiaAutomationEnabled },
                                        set: { appModel.setICloudPasswordsDiaAutomationEnabled($0) }
                                    )
                                )

                                Text(appModel.iCloudPasswordsAutomationStatus.displayText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("Waits for an iCloud Passwords plugin click in Dia, Google Chrome, or Google Chrome Canary and completes verification if required. It does not open the extension when a browser launches.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                settingsSection(title: "Window Management") {
                    settingsGroup {
                        settingsRow("Move Window to Next Monitor") {
                            VStack(alignment: .leading, spacing: 8) {
                                ShortcutRecorderField(
                                    shortcut: appModel.settings.moveWindowShortcut,
                                    hasConflict: appModel.hotKeyConflicts.contains(AppModel.moveWindowShortcutID),
                                    allowsClearing: false
                                ) { shortcut in
                                    appModel.settings.moveWindowShortcut = shortcut ?? AppSettings.defaultMoveWindowShortcut
                                    appModel.saveSettings(reloadHotKeys: true)
                                }

                                HStack(spacing: 10) {
                                    Text("Moves the focused window of the frontmost application to the next monitor.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    Button("Reset to Default") {
                                        appModel.settings.moveWindowShortcut = AppSettings.defaultMoveWindowShortcut
                                        appModel.saveSettings(reloadHotKeys: true)
                                    }
                                    .disabled(appModel.settings.moveWindowShortcut == AppSettings.defaultMoveWindowShortcut)
                                }
                            }
                        }
                    }
                }

            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .onAppear {
            appModel.ensureCredentialsLoaded(for: appModel.settings.provider)
            if appModel.discoveredModels[appModel.settings.provider.rawValue] == nil {
                appModel.refreshProviderModels(appModel.settings.provider)
            }
        }
        .onAppear {
            if appModel.settings.provider == .chatGPT {
                appModel.ensureChatGPTAuthSessionLoaded()
            }
        }
    }

    private var availableModels: [String] {
        let catalog = appModel.settings.modelCatalog(for: appModel.settings.provider)
        if catalog.contains(appModel.settings.defaultModel) {
            return catalog
        }
        return [appModel.settings.defaultModel] + catalog
    }
}

private struct ProviderModelCatalogEditor: View {
    let appModel: AppModel
    let provider: AIProvider

    @State private var newModel = ""
    @State private var modelSearch = ""
    @State private var reasoningTarget: ModelReasoningTarget?

    var body: some View {
        settingsGroup {
            HStack {
                Text("Enabled Models").font(.headline)
                Spacer()
                if appModel.refreshingModelProviders.contains(provider.rawValue) {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh Models", systemImage: "arrow.clockwise") {
                    appModel.refreshProviderModels(provider)
                }
                .disabled(appModel.refreshingModelProviders.contains(provider.rawValue))
            }
            Text(appModel.modelCatalogStatus[provider.rawValue] ?? "Refresh to discover models from this provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(catalog, id: \.self) { model in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(reasoningSummary(for: model))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if model == appModel.settings.defaultModel(for: provider) {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Reasoning…") {
                            reasoningTarget = ModelReasoningTarget(model: model)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Configure reasoning efforts for \(model)")
                        .help("Define the reasoning effort levels offered for this model")

                        Button {
                            appModel.removeProviderModel(model, for: provider)
                        } label: {
                            Image(systemName: "minus.circle")
                                .accessibilityLabel("Remove \(model)")
                        }
                        .buttonStyle(.borderless)
                        .disabled(catalog.count <= 1)
                        .help("Remove model")
                    }
                    .padding(.vertical, 3)
                }
            }

            Divider()

            TextField("Search available models", text: $modelSearch)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredDiscoveredModels, id: \.self) { model in
                        HStack {
                            Text(model).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button(catalog.contains(model) ? "Added" : "Add") {
                                appModel.addProviderModel(model, for: provider)
                            }
                            .disabled(catalog.contains(model))
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            settingsRow("Add Model") {
                HStack(spacing: 8) {
                    TextField(modelPlaceholder, text: $newModel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addModel)

                    Button("Add") {
                        addModel()
                    }
                    .disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text("Model IDs are stored separately for each provider.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reset to Defaults") {
                    appModel.resetProviderModelCatalog(for: provider)
                }
                .disabled(catalog == AppSettings.modelCatalog(for: provider))
            }
        }
        .sheet(item: $reasoningTarget) { target in
            ModelReasoningEditor(appModel: appModel, provider: provider, model: target.model)
        }
    }

    private var catalog: [String] {
        appModel.settings.modelCatalog(for: provider)
    }

    private func reasoningSummary(for model: String) -> String {
        let modes = appModel.availableReasoningModes(for: model, provider: provider).map(\.displayName).joined(separator: ", ")
        let isManual = appModel.settings.manualReasoningEfforts(for: model, provider: provider) != nil
        let source: String
        if isManual { source = "Manual" }
        else if appModel.modelCapabilities[provider.rawValue]?[model] != nil { source = "Provider catalog" }
        else { source = "No capability data" }
        return "Reasoning: \(modes) · \(source)"
    }

    private var filteredDiscoveredModels: [String] {
        let models = appModel.discoveredModels[provider.rawValue] ?? []
        return modelSearch.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(modelSearch) }
    }

    private var modelPlaceholder: String {
        switch provider {
        case .openRouter:
            return "vendor/model-id"
        case .deepSeek:
            return "deepseek-model-id"
        case .chatGPT:
            return "gpt-5.4"
        }
    }

    private func addModel() {
        let model = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        appModel.addProviderModel(model, for: provider)
        newModel = ""
    }
}

private struct ModelReasoningTarget: Identifiable {
    let model: String
    var id: String { model }
}

private struct ModelReasoningEditor: View {
    let appModel: AppModel
    let provider: AIProvider
    let model: String

    @Environment(\.dismiss) private var dismiss
    @State private var useManualEfforts: Bool
    @State private var selectedEfforts: Set<ReasoningMode>

    init(appModel: AppModel, provider: AIProvider, model: String) {
        self.appModel = appModel
        self.provider = provider
        self.model = model
        let manual = appModel.settings.manualReasoningEfforts(for: model, provider: provider)
        _useManualEfforts = State(initialValue: manual != nil)
        _selectedEfforts = State(initialValue: Set(manual ?? appModel.availableReasoningModes(for: model, provider: provider).filter { $0.effort != nil }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reasoning Efforts").font(.title2.bold())
            Text("\(provider.displayName) · \(model)")
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Definition", selection: $useManualEfforts) {
                Text("Automatic (catalog + verified cache)").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.radioGroup)

            if useManualEfforts {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(ReasoningMode.allCases.filter { $0.effort != nil }) { mode in
                        Toggle(mode.displayName, isOn: Binding(
                            get: { selectedEfforts.contains(mode) },
                            set: { enabled in
                                if enabled { selectedEfforts.insert(mode) }
                                else { selectedEfforts.remove(mode) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                Text("Auto uses the provider default. None sends an explicit none effort and is separate from Off. Leave every effort unchecked to offer Auto only. These choices apply to AI Commands; the provider must accept the efforts you select.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Use provider metadata or verified discovery results. Refresh Models checks new, expired, or outdated entries, including support for None. Saving Automatic removes this model’s manual definition.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    appModel.setManualReasoningEfforts(useManualEfforts ? Array(selectedEfforts) : nil, for: model, provider: provider)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct MemorySettingsView: View {
    let appModel: AppModel
    @State private var searchText = ""
    @State private var editingMemory: AIMemoryEntry?
    @State private var isShowingMemoryEditor = false
    @State private var showingDeleteConfirmation = false

    private var filteredMemories: [AIMemoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let memories = appModel.memoryEntries.sorted { $0.updatedAt > $1.updatedAt }
        guard !query.isEmpty else { return memories }
        return memories.filter { memory in
            memory.title.localizedCaseInsensitiveContains(query)
                || memory.summary.localizedCaseInsensitiveContains(query)
                || memory.source.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection(title: "AI Memory") {
                    settingsGroup {
                        Toggle(
                            "Remember useful context from AI Commands",
                            isOn: Binding(
                                get: { appModel.settings.memoryEnabled },
                                set: {
                                    appModel.settings.memoryEnabled = $0
                                    appModel.saveSettings()
                                }
                            )
                        )
                        .padding(.vertical, 10)

                        Divider()

                        settingsRow("Saved Memories") {
                            Stepper(
                                value: Binding(
                                    get: { appModel.settings.memoryLimit },
                                    set: {
                                        appModel.settings.memoryLimit = AppSettings.normalizedMemoryLimit($0)
                                        appModel.saveSettings()
                                    }
                                ),
                                in: 10...500,
                                step: 10
                            ) {
                                Text("\(appModel.settings.memoryLimit)")
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: 180, alignment: .leading)
                        }

                        Divider()

                        Text("Memories are stored locally in Application Support and injected only as compact context when they match a command selection.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }

                settingsSection(title: "Data") {
                    settingsGroup {
                        HStack(spacing: 10) {
                            Button {
                                editingMemory = nil
                                isShowingMemoryEditor = true
                            } label: {
                                Label("Add Memory", systemImage: "plus")
                            }

                            Button("Delete All Memories", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                            .disabled(appModel.memoryEntries.isEmpty)

                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                }

                settingsSection(title: "Saved Memories") {
                    settingsGroup {
                        TextField("Search memories", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .padding(.vertical, 10)

                        if filteredMemories.isEmpty {
                            Divider()
                            ContentUnavailableView(
                                searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Memories" : "No Matches",
                                systemImage: "brain",
                                description: Text("Add personal context, preferences, project facts, or writing style notes.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        } else {
                            ForEach(filteredMemories) { memory in
                                Divider()
                                MemoryRow(
                                    memory: memory,
                                    onEdit: {
                                        editingMemory = memory
                                        isShowingMemoryEditor = true
                                    },
                                    onDelete: {
                                        appModel.deleteMemory(id: memory.id)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $isShowingMemoryEditor) {
            MemoryEditorSheet(appModel: appModel, memory: editingMemory)
        }
        .alert("Delete All AI Memories?", isPresented: $showingDeleteConfirmation) {
            Button("Delete All", role: .destructive) {
                appModel.clearMemory()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all saved AI memories on this Mac.")
        }
    }
}

private struct MemoryRow: View {
    let memory: AIMemoryEntry
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: memory.source == .chat ? "bubble.left.and.text.bubble.right" : "command")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 5) {
                    Text(memory.title)
                        .font(.headline)
                        .lineLimit(1)

                    Text(memory.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        Text(memory.source.rawValue)
                        Text(memory.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                Spacer()

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit memory")

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete memory")
            }
        }
        .padding(.vertical, 12)
    }
}

private struct MemoryEditorSheet: View {
    let appModel: AppModel
    let memory: AIMemoryEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var summary: String
    @State private var source: AIMemorySource

    init(appModel: AppModel, memory: AIMemoryEntry?) {
        self.appModel = appModel
        self.memory = memory
        _title = State(initialValue: memory?.title ?? "")
        _summary = State(initialValue: memory?.summary ?? "")
        _source = State(initialValue: memory?.source ?? .command)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(memory == nil ? "Add Memory" : "Edit Memory")
                .font(.title2.weight(.semibold))

            Text(source == .chat ? "Source: Saved conversation" : "Source: AI Command")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Title")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Short label", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $summary)
                    .font(.body)
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save() {
        if let memory {
            appModel.updateMemory(memory, title: title, summary: summary, source: source)
        } else {
            appModel.addMemory(title: title, summary: summary, source: source)
        }
        dismiss()
    }
}

private struct ClipboardHistorySettingsView: View {
    let appModel: AppModel
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection(title: "Retention") {
                    settingsGroup {
                        settingsRow("Saved History") {
                            Picker(
                                "",
                                selection: Binding(
                                    get: { appModel.settings.clipboardHistoryRetention },
                                    set: { retention in
                                        appModel.settings.clipboardHistoryRetention = retention
                                        appModel.saveSettings()
                                        appModel.pruneClipboardHistoryForCurrentRetention()
                                    }
                                )
                            ) {
                                ForEach(ClipboardHistoryRetention.allCases) { retention in
                                    Text(retention.displayName).tag(retention)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220, alignment: .leading)
                        }

                        Divider()

                        Text("Clipboard history is persisted locally and pruned automatically based on the selected retention window.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }

                settingsSection(title: "Data") {
                    settingsGroup {
                        HStack(spacing: 10) {
                            Button("Delete All History", role: .destructive) {
                                showingDeleteAllConfirmation = true
                            }
                            .disabled(appModel.clipboardHistoryEntries.isEmpty)

                            Spacer()
                        }

                        Divider()

                        Text("This permanently deletes all saved clipboard history on this Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }

                settingsSection(title: "Shortcut") {
                    settingsGroup {
                        settingsRow("Global Shortcut") {
                            VStack(alignment: .leading, spacing: 8) {
                                ShortcutRecorderField(
                                    shortcut: appModel.settings.clipboardHistoryShortcut,
                                    hasConflict: appModel.hotKeyConflicts.contains(AppModel.clipboardHistoryShortcutID)
                                ) { shortcut in
                                    appModel.settings.clipboardHistoryShortcut = shortcut
                                    appModel.saveSettings(reloadHotKeys: true)
                                }

                                Text("Use a global shortcut to open the Clipboard History window from anywhere.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .task {
            await appModel.loadClipboardHistoryIfNeeded()
        }
        .alert("Delete All Clipboard History?", isPresented: $showingDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                appModel.clearClipboardHistory()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

private struct CommandsSettingsView: View {
    let appModel: AppModel

    var body: some View {
        HSplitView {
            commandListColumn
                .frame(minWidth: 240, idealWidth: 250, maxWidth: 280)

            Group {
                if let index = selectedCommandIndex {
                    CommandEditorView(appModel: appModel, commandIndex: index)
                } else {
                    ContentUnavailableView(
                        "Select a Command",
                        systemImage: "command.square",
                        description: Text("Choose a command in the sidebar to edit its behavior.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var commandListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Commands")
                    .font(.headline)

                Spacer()

                Button {
                    appModel.addCommand()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Add Command")

                Button {
                    appModel.deleteSelectedCommand()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Delete Selected Command")
                .disabled(appModel.selectedCommandStableID == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            List(selection: commandSelectionBinding) {
                ForEach(appModel.settings.commands) { command in
                    CommandListRow(
                        command: command,
                        hasConflict: appModel.hotKeyConflicts.contains(command.id)
                    )
                    .tag(command.id)
                }
                .onMove(perform: appModel.moveCommand)
            }
            .listStyle(.inset)
        }
    }

    private var selectedCommandIndex: Int? {
        guard let selectedCommandStableID else { return nil }
        return appModel.settings.commands.firstIndex(where: { $0.id == selectedCommandStableID })
    }

    private var selectedCommandStableID: UUID? {
        appModel.selectedCommandStableID
    }

    private var commandSelectionBinding: Binding<UUID?> {
        Binding(
            get: { appModel.selectedCommandStableID },
            set: { appModel.selectedCommandStableID = $0 }
        )
    }
}

func settingsSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title)
            .font(.title3.weight(.semibold))
        content()
    }
}

func settingsGroup<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        content()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    )
}

func settingsRow<Content: View>(
    _ label: String,
    @ViewBuilder content: () -> Content
) -> some View {
    HStack(alignment: .center, spacing: 24) {
        Text(label)
            .frame(width: 180, alignment: .leading)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10)
}

private struct CommandListRow: View {
    let command: AICommand
    let hasConflict: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(command.title)
                    .lineLimit(1)

                if hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("This shortcut conflicts with another command.")
                }
            }

            HStack(spacing: 8) {
                Text(command.commandID)
                if let shortcut = command.shortcut {
                    Text(shortcut.displayString)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct CommandEditorView: View {
    let appModel: AppModel
    let commandIndex: Int

    private var command: AICommand {
        appModel.settings.commands[commandIndex]
    }

    var body: some View {
        Form {
            Section {
                Text(command.title)
                    .font(.title2.weight(.semibold))
                Text("Edit prompt behavior, output handling, and global shortcut.")
                    .foregroundStyle(.secondary)
            }

            Section("Identity") {
                TextField("Command ID", text: binding(\.commandID))

                if appModel.duplicateCommandIdentifiers.contains(command.id) {
                    Label("This ID is duplicated. Keep command IDs unique.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }

                TextField("Command Title", text: binding(\.title))
            }

            Section("Shortcut") {
                ShortcutRecorderField(
                    shortcut: command.shortcut,
                    hasConflict: appModel.hotKeyConflicts.contains(command.id)
                ) { shortcut in
                    appModel.settings.commands[commandIndex].shortcut = shortcut
                    appModel.saveSettings(reloadHotKeys: true)
                }
            }

            Section("Model") {
                Toggle(
                    "Use default model",
                    isOn: Binding(
                        get: { command.resolvedModel == nil },
                        set: { useDefault in
                            appModel.settings.commands[commandIndex].modelOverride = useDefault ? nil : appModel.settings.defaultModel
                            appModel.saveSettings()
                        }
                    )
                )

                if command.resolvedModel != nil {
                    Picker(
                        "Override Model",
                        selection: Binding(
                            get: { appModel.settings.commands[commandIndex].modelOverride ?? appModel.settings.defaultModel },
                            set: {
                                appModel.settings.commands[commandIndex].modelOverride = $0
                                appModel.saveSettings()
                            }
                        )
                    ) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                Toggle("Use default reasoning", isOn: binding(\.useDefaultReasoning))
                if command.useDefaultReasoning {
                    Text("Default: \(appModel.defaultReasoningMode(for: command.effectiveModel(defaultModel: appModel.settings.defaultModel)).displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Reasoning", selection: reasoningModeBinding) {
                    ForEach(availableReasoningModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(command.useDefaultReasoning)
                .help("Auto uses the provider default. Available effort levels depend on the selected model.")
            }

            Section("Output") {
                Toggle("Show popup after completion", isOn: binding(\.showPopup))
                Toggle("Save to Obsidian", isOn: binding(\.saveToObsidian))
                if command.saveToObsidian {
                    TextField(
                        "Obsidian Vault Name or Path",
                        text: Binding(
                            get: { appModel.settings.obsidianVaultName },
                            set: {
                                appModel.settings.obsidianVaultName = $0
                                appModel.saveSettings()
                            }
                        )
                    )
                    TextField(
                        "Note Subfolder (Optional)",
                        text: Binding(
                            get: { appModel.settings.obsidianSubfolder },
                            set: {
                                appModel.settings.obsidianSubfolder = $0
                                appModel.saveSettings()
                            }
                        )
                    )
                    Text("Writes Markdown directly to the local Vault folder in the background without stealing focus, falling back to obsidian:// when needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Supports runtime context variables injected before sending the prompt.")
                    .foregroundStyle(.secondary)

                FlowLayout(spacing: 8) {
                    TokenChip(label: "{{text}}")
                    TokenChip(label: "{{command_title}}")
                    TokenChip(label: "{{app_name}}")
                    TokenChip(label: "{{clipboard}}")
                    TokenChip(label: "{{date}}")
                }

                TextEditor(text: binding(\.promptTemplate))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 280)
            } header: {
                Text("Prompt Template")
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AICommand, Value>) -> Binding<Value> {
        Binding(
            get: { appModel.settings.commands[commandIndex][keyPath: keyPath] },
            set: {
                appModel.settings.commands[commandIndex][keyPath: keyPath] = $0
                appModel.saveSettings()
            }
        )
    }

    private var availableModels: [String] {
        let catalog = appModel.settings.modelCatalog(for: appModel.settings.provider)
        if let override = command.resolvedModel, !catalog.contains(override) {
            return [override] + catalog
        }
        return catalog
    }

    private var availableReasoningModes: [ReasoningMode] {
        appModel.availableReasoningModes(for: command.effectiveModel(defaultModel: appModel.settings.defaultModel))
    }

    private var reasoningModeBinding: Binding<ReasoningMode> {
        Binding(
            get: { appModel.commandReasoningMode(for: command, model: command.effectiveModel(defaultModel: appModel.settings.defaultModel)) },
            set: { mode in
                appModel.settings.commands[commandIndex].reasoningMode = mode
                appModel.saveSettings()
            }
        )
    }

}

private struct TokenChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
            )
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > maxWidth, currentRowWidth > 0 {
                totalHeight += currentRowHeight + spacing
                totalWidth = max(totalWidth, currentRowWidth - spacing)
                currentRowWidth = 0
                currentRowHeight = 0
            }

            currentRowWidth += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }

        totalHeight += currentRowHeight
        totalWidth = max(totalWidth, currentRowWidth - spacing)

        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var cursor = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x + size.width > bounds.maxX, cursor.x > bounds.minX {
                cursor.x = bounds.minX
                cursor.y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: cursor,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            cursor.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
