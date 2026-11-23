import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    let appModel: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: selectionBinding) { section in
                SettingsSidebarRow(
                    section: section,
                    badgeKind: badgeKind(for: section)
                )
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 245)
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                        .opacity(0.45)
                    HStack(spacing: 6) {
                        Text("Daydream")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(appModel.applicationVersionDisplay)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        } detail: {
            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(
            SettingsWindowConfigurator { window in
                appModel.registerSettingsWindow(window)
            }
        )
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

    private func badgeKind(for section: SettingsSection) -> SettingsSidebarBadge? {
        switch section {
        case .general:
            if !appModel.diagnostics.accessibilityTrusted {
                return .warning("Accessibility permission required")
            }
            if appModel.hotKeyConflicts.contains(AppModel.moveWindowShortcutID) {
                return .warning("Shortcut conflict")
            }
            return nil
        case .clipboardHistory:
            if appModel.hotKeyConflicts.contains(AppModel.clipboardHistoryShortcutID) {
                return .warning("Shortcut conflict")
            }
            return nil
        case .commands:
            let hasCommandConflict = appModel.settings.commands.contains {
                appModel.hotKeyConflicts.contains($0.id) || appModel.duplicateCommandIdentifiers.contains($0.id)
            }
            return hasCommandConflict ? .warning("Command shortcut or ID conflict") : nil
        case .memory, .inputSources, .versionHistory:
            return nil
        }
    }
}

private enum SettingsSidebarBadge {
    case warning(String)
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let badgeKind: SettingsSidebarBadge?

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 10) {
            SettingsSidebarIcon(section: section)

            Text(section.rawValue)
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 4)

            if case let .warning(helpText) = badgeKind {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .opacity(appearsActive ? 1.0 : 0.55)
                    .help(helpText)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsSidebarIcon: View {
    let section: SettingsSection

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)

            Image(systemName: iconName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .saturation(appearsActive ? 1.0 : 0.35)
        .opacity(appearsActive ? 1.0 : 0.72)
    }

    private var iconName: String {
        switch section {
        case .general:
            return "gearshape.fill"
        case .memory:
            return "brain"
        case .clipboardHistory:
            return "clipboard.fill"
        case .inputSources:
            return "keyboard.fill"
        case .commands:
            return "command"
        case .versionHistory:
            return "clock.arrow.circlepath"
        }
    }

    private var gradientColors: [Color] {
        switch section {
        case .general:
            return [Color(red: 0.55, green: 0.57, blue: 0.61), Color(red: 0.41, green: 0.43, blue: 0.47)]
        case .memory:
            return [Color(red: 0.69, green: 0.38, blue: 0.94), Color(red: 0.53, green: 0.24, blue: 0.82)]
        case .clipboardHistory:
            return [Color(red: 0.22, green: 0.58, blue: 0.98), Color(red: 0.11, green: 0.43, blue: 0.88)]
        case .inputSources:
            return [Color(red: 0.16, green: 0.72, blue: 0.74), Color(red: 0.08, green: 0.56, blue: 0.60)]
        case .commands:
            return [Color(red: 0.98, green: 0.57, blue: 0.20), Color(red: 0.89, green: 0.41, blue: 0.10)]
        case .versionHistory:
            return [Color(red: 0.37, green: 0.42, blue: 0.92), Color(red: 0.26, green: 0.30, blue: 0.78)]
        }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        SettingsWindowConfigurationView(onResolveWindow: onResolveWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SettingsWindowConfigurationView else { return }
        view.onResolveWindow = onResolveWindow
        view.configureWindow()
    }
}

private final class SettingsWindowConfigurationView: NSView {
    var onResolveWindow: (NSWindow) -> Void

    init(onResolveWindow: @escaping (NSWindow) -> Void) {
        self.onResolveWindow = onResolveWindow
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }

        onResolveWindow(window)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }
}

private struct VersionHistorySettingsView: View {
    let appModel: AppModel

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                title: "Version History",
                subtitle: "Inspect application build version, Git repository status, and recent commits."
            ) {
                Button {
                    Task {
                        await appModel.refreshDiagnostics()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            settingsSection(title: "Application") {
                settingsGroup {
                    settingsRow("Version") {
                        Text(appModel.applicationVersionDisplay)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if appModel.diagnostics.gitVersion.isAvailable {
                        Divider()

                        settingsRow("Git Commit") {
                            Text(appModel.diagnostics.gitVersion.shortCommitHash)
                                .font(.system(.callout, design: .monospaced, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                                .textSelection(.enabled)
                        }

                        Divider()

                        settingsRow("Branch") {
                            Text(appModel.diagnostics.gitVersion.branch)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Divider()

                        settingsRow("Repository") {
                            Text(appModel.diagnostics.gitVersion.repositoryPath)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } else {
                        Divider()

                        Text(appModel.diagnostics.gitVersion.availabilityMessage.isEmpty
                            ? "Git metadata is unavailable."
                            : appModel.diagnostics.gitVersion.availabilityMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            }

            settingsSection(title: "Git Commit History") {
                settingsGroup {
                    if appModel.diagnostics.gitCommitHistory.isEmpty {
                        Text("No Git commit history is available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(appModel.diagnostics.gitCommitHistory.enumerated()), id: \.offset) { index, commit in
                            if index > 0 {
                                Divider()
                            }
                            commitRow(commit)
                        }
                    }
                }
            }

            settingsSection(title: "Actions") {
                settingsGroup {
                    HStack(spacing: 10) {
                        Button {
                            appModel.revealRepository()
                        } label: {
                            Label("Reveal Repository", systemImage: "folder")
                        }
                        .disabled(!appModel.diagnostics.gitVersion.isAvailable)

                        Button {
                            appModel.revealVersionLogFile()
                        } label: {
                            Label("Reveal Version Log", systemImage: "doc.text")
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task {
            await appModel.refreshDiagnostics()
        }
    }

    @ViewBuilder
    private func commitRow(_ commit: String) -> some View {
        let parts = commit.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(parts[0]))
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .textSelection(.enabled)

                Text(String(parts[1]))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
        } else {
            Text(commit)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 7)
        }
    }
}

private struct GeneralSettingsView: View {
    let appModel: AppModel

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                title: "General",
                subtitle: "Configure AI providers, default models, permissions, and window shortcuts."
            )

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
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
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
                            .frame(maxWidth: 340)
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
                            .frame(maxWidth: 340)
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
                            .frame(maxWidth: 340)
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
                            .frame(maxWidth: 340)
                        }

                    case .chatGPT:
                        VStack(alignment: .leading, spacing: 6) {
                            settingsRow(
                                "ChatGPT Account",
                                subtitle: appModel.chatGPTAuthSession != nil
                                    ? "Uses your ChatGPT plan via OAuth + PKCE. Tokens refresh automatically."
                                    : "Authenticate in your browser to use your ChatGPT Plus or Pro plan without an API key."
                            ) {
                                if appModel.isSigningInWithChatGPT {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Waiting for browser…")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        Button("Cancel") {
                                            appModel.cancelChatGPTSignIn()
                                        }
                                    }
                                } else if let session = appModel.chatGPTAuthSession {
                                    HStack(spacing: 8) {
                                        SettingsStatusPill(
                                            text: session.displayIdentity,
                                            color: session.hasDirectPlanUsageScope ? .green : .orange
                                        )
                                        Button("Sign Out") {
                                            appModel.signOutOfChatGPT()
                                        }
                                    }
                                } else {
                                    Button("Sign in with ChatGPT") {
                                        appModel.signInWithChatGPT()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
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
                                    .padding(.bottom, 6)
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
                        .fixedSize()
                    }

                    Divider()

                    settingsRow(
                        "Default Reasoning",
                        subtitle: "Saved separately per default model and used by commands with default reasoning."
                    ) {
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
                        .fixedSize()
                    }
                }
            }

            ProviderModelCatalogEditor(
                appModel: appModel,
                provider: appModel.settings.provider
            )
            .id(appModel.settings.provider)

            settingsSection(title: "Permissions") {
                settingsGroup {
                    settingsRow("Accessibility") {
                        HStack(spacing: 8) {
                            SettingsStatusPill(
                                text: appModel.diagnostics.accessibilityTrusted ? "Granted" : "Required",
                                color: appModel.diagnostics.accessibilityTrusted ? .green : .orange
                            )

                            if !appModel.diagnostics.accessibilityTrusted {
                                Button("Request Access") {
                                    appModel.promptForAccessibilityPermission()
                                }
                            }

                            Button("Open Settings") {
                                appModel.openAccessibilitySettings()
                            }
                        }
                    }

                    Divider()

                    settingsRow(
                        "iCloud Passwords for Browsers",
                        subtitle: "\(appModel.iCloudPasswordsAutomationStatus.displayText) · Completes verification after clicking the plugin in Dia, Chrome, or Chrome Canary."
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { appModel.settings.iCloudPasswordsDiaAutomationEnabled },
                                set: { appModel.setICloudPasswordsDiaAutomationEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Enable iCloud Passwords verification automation for browsers")
                    }
                }
            }

            settingsSection(title: "Window Management") {
                settingsGroup {
                    settingsRow(
                        "Move Window to Next Monitor",
                        subtitle: "Moves the focused window of the frontmost application to the next display."
                    ) {
                        HStack(spacing: 8) {
                            ShortcutRecorderField(
                                shortcut: appModel.settings.moveWindowShortcut,
                                hasConflict: appModel.hotKeyConflicts.contains(AppModel.moveWindowShortcutID),
                                allowsClearing: false
                            ) { shortcut in
                                appModel.settings.moveWindowShortcut = shortcut ?? AppSettings.defaultMoveWindowShortcut
                                appModel.saveSettings(reloadHotKeys: true)
                            }

                            Button("Reset") {
                                appModel.settings.moveWindowShortcut = AppSettings.defaultMoveWindowShortcut
                                appModel.saveSettings(reloadHotKeys: true)
                            }
                            .disabled(appModel.settings.moveWindowShortcut == AppSettings.defaultMoveWindowShortcut)
                        }
                    }
                }
            }
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

    @Environment(\.colorScheme) private var colorScheme
    @State private var newModel = ""
    @State private var modelSearch = ""
    @State private var reasoningTarget: ModelReasoningTarget?

    var body: some View {
        settingsSection(
            title: "\(provider.displayName) Models",
            subtitle: appModel.modelCatalogStatus[provider.rawValue] ?? "Refresh to discover models from this provider."
        ) {
            HStack(spacing: 8) {
                if appModel.refreshingModelProviders.contains(provider.rawValue) {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh Models", systemImage: "arrow.clockwise") {
                    appModel.refreshProviderModels(provider)
                }
                .controlSize(.small)
                .disabled(appModel.refreshingModelProviders.contains(provider.rawValue))
            }
        } content: {
            settingsGroup {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(catalog.enumerated()), id: \.element) { index, model in
                        if index > 0 {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text(model)
                                        .font(.system(.body, design: .monospaced, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    if model == appModel.settings.defaultModel(for: provider) {
                                        Text("Default")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.92) : Color.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.14))
                                            )
                                    }
                                }

                                Text(reasoningSummary(for: model))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Button("Reasoning…") {
                                reasoningTarget = ModelReasoningTarget(model: model)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Configure reasoning efforts for \(model)")
                            .help("Define the reasoning effort levels offered for this model")

                            Button {
                                appModel.removeProviderModel(model, for: provider)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Remove \(model)")
                            }
                            .buttonStyle(.borderless)
                            .disabled(catalog.count <= 1)
                            .help("Remove model")
                        }
                        .padding(.vertical, 8)
                    }
                }

                Divider()
                    .padding(.vertical, 10)

                // Unified inset browser: search header + discovered model rows in a single container
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        TextField("Search available models", text: $modelSearch)
                            .textFieldStyle(.plain)

                        if !modelSearch.isEmpty {
                            Button {
                                modelSearch = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    if !filteredDiscoveredModels.isEmpty {
                        Divider()

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(filteredDiscoveredModels.enumerated()), id: \.element) { index, model in
                                    if index > 0 {
                                        Divider()
                                    }
                                    HStack(spacing: 8) {
                                        Text(model)
                                            .font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(.primary.opacity(0.9))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button(catalog.contains(model) ? "Added" : "Add") {
                                            appModel.addProviderModel(model, for: provider)
                                        }
                                        .controlSize(.small)
                                        .disabled(catalog.contains(model))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                        .frame(maxHeight: 190)
                    } else if !modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()

                        Text("No discovered models match “\(modelSearch)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.18) : Color.primary.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.10) : Color(nsColor: .separatorColor).opacity(0.55),
                            lineWidth: 0.5
                        )
                )

                Divider()
                    .padding(.top, 10)

                settingsRow("Add Custom Model") {
                    HStack(spacing: 8) {
                        TextField(modelPlaceholder, text: $newModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Reset to Defaults") {
                        appModel.resetProviderModelCatalog(for: provider)
                    }
                    .controlSize(.small)
                    .disabled(catalog == AppSettings.modelCatalog(for: provider))
                }
                .padding(.top, 10)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Reasoning Efforts")
                    .font(.title2.weight(.semibold))
                Text("\(provider.displayName) · \(model)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                .buttonStyle(.borderedProminent)
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
        SettingsPageContainer {
            SettingsPageHeader(
                title: "Memory",
                subtitle: "Store compact local context that automatically enriches matching AI Commands."
            )

            settingsSection(title: "AI Memory") {
                settingsGroup {
                    settingsRow(
                        "Remember Context",
                        subtitle: "Memories are stored locally in Application Support and injected only when relevant."
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { appModel.settings.memoryEnabled },
                                set: {
                                    appModel.settings.memoryEnabled = $0
                                    appModel.saveSettings()
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Remember useful context from AI Commands")
                    }

                    Divider()

                    settingsRow("Maximum Entries") {
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
                        .fixedSize()
                    }
                }
            }

            settingsSection(title: "Saved Memories") {
                HStack(spacing: 8) {
                    Button {
                        editingMemory = nil
                        isShowingMemoryEditor = true
                    } label: {
                        Label("Add Memory", systemImage: "plus")
                    }
                    .controlSize(.small)

                    Button("Delete All", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(appModel.memoryEntries.isEmpty)
                }
            } content: {
                settingsGroup {
                    SettingsSearchField(placeholder: "Search memories", text: $searchText)
                        .padding(.vertical, 4)

                    if filteredMemories.isEmpty {
                        Divider()
                            .padding(.top, 8)
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
                                .padding(.top, 4)
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: memory.source == .chat ? "bubble.left.and.text.bubble.right" : "command")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(memory.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(memory.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    Text(memory.source.rawValue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                    Text(memory.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
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
            .padding(.top, 2)
        }
        .padding(.vertical, 10)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(memory == nil ? "Add Memory" : "Edit Memory")
                    .font(.title2.weight(.semibold))

                Text(source == .chat ? "Source: Saved conversation" : "Source: AI Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Short label", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Memory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $summary)
                    .font(.body)
                    .padding(6)
                    .frame(minHeight: 160)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.75)
                    )
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
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
        SettingsPageContainer {
            SettingsPageHeader(
                title: "Clipboard History",
                subtitle: "Configure local retention period, stored entries, and quick-open shortcut."
            )

            settingsSection(title: "Retention") {
                settingsGroup {
                    settingsRow(
                        "Saved History",
                        subtitle: "Clipboard history is persisted locally and pruned automatically."
                    ) {
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
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            settingsSection(title: "Shortcut") {
                settingsGroup {
                    settingsRow(
                        "Global Shortcut",
                        subtitle: "Open the Clipboard History window from anywhere."
                    ) {
                        ShortcutRecorderField(
                            shortcut: appModel.settings.clipboardHistoryShortcut,
                            hasConflict: appModel.hotKeyConflicts.contains(AppModel.clipboardHistoryShortcutID)
                        ) { shortcut in
                            appModel.settings.clipboardHistoryShortcut = shortcut
                            appModel.saveSettings(reloadHotKeys: true)
                        }
                    }
                }
            }

            settingsSection(title: "Data") {
                settingsGroup {
                    settingsRow(
                        "Local History",
                        subtitle: "Permanently deletes all saved clipboard entries on this Mac."
                    ) {
                        Button("Delete All History", role: .destructive) {
                            showingDeleteAllConfirmation = true
                        }
                        .disabled(appModel.clipboardHistoryEntries.isEmpty)
                    }
                }
            }
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
                .frame(minWidth: 235, idealWidth: 255, maxWidth: 290)

            Group {
                if let index = selectedCommandIndex {
                    CommandEditorView(appModel: appModel, commandIndex: index)
                } else {
                    ContentUnavailableView(
                        "Select a Command",
                        systemImage: "command.square",
                        description: Text("Choose a command in the list to edit its prompt, model, and shortcut.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var commandListColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("AI Commands")
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
                            || appModel.duplicateCommandIdentifiers.contains(command.id)
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

// MARK: - Shared macOS 27 Native Settings Components

struct SettingsPageContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
    }
}

struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            trailing()
        }
        .padding(.bottom, 2)
    }
}

struct SettingsStatusPill: View {
    let text: String
    let color: Color

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(pillOpacity))
        )
        .foregroundStyle(appearsActive ? .primary : .secondary)
    }

    private var pillOpacity: Double {
        if !appearsActive { return 0.09 }
        return colorScheme == .dark ? 0.20 : 0.13
    }
}

struct SettingsSearchField: View {
    let placeholder: String
    @Binding var text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.18) : Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.10) : Color(nsColor: .separatorColor).opacity(0.65),
                    lineWidth: 0.75
                )
        )
    }
}

struct SettingsKeycapBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            )
    }
}

struct SettingsGroupCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 0.5)
        )
    }

    private var cardFill: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.048)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorder: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.11)
        }
        return Color.black.opacity(0.09)
    }
}

func settingsSection<Content: View>(
    title: String,
    subtitle: String? = nil,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)

        content()
    }
}

func settingsSection<Trailing: View, Content: View>(
    title: String,
    subtitle: String? = nil,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)

            Spacer()

            trailing()
        }
        content()
    }
}

func settingsGroup<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    SettingsGroupCard {
        content()
    }
}

func settingsRow<Content: View>(
    _ label: String,
    subtitle: String? = nil,
    alignment: VerticalAlignment = .center,
    @ViewBuilder content: () -> Content
) -> some View {
    HStack(alignment: alignment, spacing: 20) {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.body)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
}

private struct CommandListRow: View {
    let command: AICommand
    let hasConflict: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(command.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if hasConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("This command has a shortcut or ID conflict.")
                    }
                }

                Text(command.commandID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let shortcut = command.shortcut {
                SettingsKeycapBadge(text: shortcut.displayString)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CommandEditorView: View {
    let appModel: AppModel
    let commandIndex: Int

    @Environment(\.colorScheme) private var colorScheme

    private var command: AICommand {
        appModel.settings.commands[commandIndex]
    }

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                title: command.title.isEmpty ? "Untitled Command" : command.title,
                subtitle: "Edit prompt behavior, model selection, output handling, and global shortcut."
            )

            settingsSection(title: "Identity") {
                settingsGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        settingsRow("Command ID") {
                            TextField("Command ID", text: binding(\.commandID))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                        }

                        if appModel.duplicateCommandIdentifiers.contains(command.id) {
                            Label("This ID is duplicated. Keep command IDs unique.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.bottom, 6)
                        }
                    }

                    Divider()

                    settingsRow("Command Title") {
                        TextField("Command Title", text: binding(\.title))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                    }
                }
            }

            settingsSection(title: "Shortcut") {
                settingsGroup {
                    settingsRow("Global Shortcut") {
                        ShortcutRecorderField(
                            shortcut: command.shortcut,
                            hasConflict: appModel.hotKeyConflicts.contains(command.id)
                        ) { shortcut in
                            appModel.settings.commands[commandIndex].shortcut = shortcut
                            appModel.saveSettings(reloadHotKeys: true)
                        }
                    }
                }
            }

            settingsSection(title: "Model & Reasoning") {
                settingsGroup {
                    settingsRow("Use Default Model") {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { command.resolvedModel == nil },
                                set: { useDefault in
                                    appModel.settings.commands[commandIndex].modelOverride = useDefault ? nil : appModel.settings.defaultModel
                                    appModel.saveSettings()
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Use default model")
                    }

                    if command.resolvedModel != nil {
                        Divider()

                        settingsRow("Override Model") {
                            Picker(
                                "",
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
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }

                    Divider()

                    settingsRow(
                        "Use Default Reasoning",
                        subtitle: command.useDefaultReasoning
                            ? "Currently \(appModel.defaultReasoningMode(for: command.effectiveModel(defaultModel: appModel.settings.defaultModel)).displayName)"
                            : nil
                    ) {
                        Toggle("", isOn: binding(\.useDefaultReasoning))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Use default reasoning")
                    }

                    Divider()

                    settingsRow("Reasoning Effort") {
                        Picker("", selection: reasoningModeBinding) {
                            ForEach(availableReasoningModes) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(command.useDefaultReasoning)
                        .help("Auto uses the provider default. Available effort levels depend on the selected model.")
                    }
                }
            }

            settingsSection(title: "Output") {
                settingsGroup {
                    settingsRow("Show Popup After Completion") {
                        Toggle("", isOn: binding(\.showPopup))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Show popup after completion")
                    }

                    Divider()

                    settingsRow("Save to Obsidian") {
                        Toggle("", isOn: binding(\.saveToObsidian))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Save to Obsidian")
                    }

                    if command.saveToObsidian {
                        Divider()

                        settingsRow("Obsidian Vault") {
                            TextField(
                                "Vault Name or Path",
                                text: Binding(
                                    get: { appModel.settings.obsidianVaultName },
                                    set: {
                                        appModel.settings.obsidianVaultName = $0
                                        appModel.saveSettings()
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        }

                        Divider()

                        settingsRow(
                            "Note Subfolder",
                            subtitle: "Writes Markdown directly to the local Vault folder in the background without stealing focus."
                        ) {
                            TextField(
                                "Optional subfolder",
                                text: Binding(
                                    get: { appModel.settings.obsidianSubfolder },
                                    set: {
                                        appModel.settings.obsidianSubfolder = $0
                                        appModel.saveSettings()
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        }
                    }
                }
            }

            settingsSection(title: "Prompt Template") {
                settingsGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Click a variable to append it to the prompt template.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 6) {
                            ForEach(["{{text}}", "{{command_title}}", "{{app_name}}", "{{clipboard}}", "{{date}}"], id: \.self) { token in
                                TokenChip(label: token) {
                                    insertToken(token)
                                }
                            }
                        }

                        TextEditor(text: binding(\.promptTemplate))
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .frame(minHeight: 240)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        colorScheme == .dark ? Color.white.opacity(0.10) : Color(nsColor: .separatorColor).opacity(0.65),
                                        lineWidth: 0.75
                                    )
                            )
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func insertToken(_ token: String) {
        let current = appModel.settings.commands[commandIndex].promptTemplate
        if current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") {
            appModel.settings.commands[commandIndex].promptTemplate = current + token
        } else {
            appModel.settings.commands[commandIndex].promptTemplate = current + " " + token
        }
        appModel.saveSettings()
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
    var onInsert: () -> Void

    @State private var isHovering = false
    @State private var recentlyInserted = false

    var body: some View {
        Button {
            onInsert()
            recentlyInserted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                recentlyInserted = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(.caption, design: .monospaced))
                if recentlyInserted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.065))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isHovering ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Click to append \(label) to prompt")
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
