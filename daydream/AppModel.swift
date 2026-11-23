import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    // MARK: - Constants

    static let diagnosticsWindowID = "diagnostics-window"
    static let clipboardHistoryWindowID = "clipboard-history-window"
    static let clipboardHistoryShortcutID = UUID(uuidString: "C1A4D580-13EF-4A73-A1B1-3D4F18E6B631")!
    static let moveWindowShortcutID = UUID(uuidString: "9869C326-3E95-4A49-AB49-BD7A30DDDB58")!

    // MARK: - Properties

    // The application's settings.
    var settings = AppSettings.default
    // A snapshot of the application's diagnostics.
    var diagnostics = DiagnosticsSnapshot()
    // Whether the application is currently executing a command.
    var isExecuting = false
    // The ID of the command currently being executed.
    var executingCommandID: UUID?
    // The title of the command currently being executed.
    var executingCommandTitle: String?
    // The currently selected section in the settings view.
    var selectedSettingsSection: SettingsSection = .general
    // The ID of the currently selected command.
    var selectedCommandStableID: UUID?
    var clipboardHistoryEntries: [ClipboardHistorySummary] = []
    var selectedClipboardEntryID: UUID?
    var selectedClipboardEntryDetail: ClipboardHistoryEntry?
    var isLoadingSelectedClipboardEntry = false
    var hasMoreClipboardHistoryEntries = false
    var clipboardHistorySearchText = ""
    var clipboardHistorySelectedFilter: ClipboardContentType = .all
    var clipboardHistoryOpenRequestToken = UUID()
    var memoryEntries: [AIMemoryEntry] = []
    // A set of command IDs that have conflicting hotkeys.
    var hotKeyConflicts: Set<UUID> = []
    // A set of command IDs that have duplicate identifiers.
    var duplicateCommandIdentifiers: Set<UUID> = []
    // A list of issues related to hotkeys.
    var hotKeyIssues: [String] = []
    var iCloudPasswordsAutomationStatus = ICloudPasswordsAutomationStatus.disabled
    var inputSourceSwitchingStatus = InputSourceSwitchingStatus.disabled
    var availableInputSources: [KeyboardInputSource] = []
    var automaticDefaultEnglishInputSource: KeyboardInputSource?
    var openRouterReasoningCapabilities: [String: OpenRouterReasoningCapability] = [:]
    var discoveredModels: [String: [String]] = [:]
    var modelCapabilities: [String: [String: OpenRouterReasoningCapability]] = [:]
    var localVerifiedReasoningCapabilities = VerifiedReasoningCapability.localAndBundled()
    var modelCatalogStatus: [String: String] = [:]
    var refreshingModelProviders: Set<String> = []


    var applicationVersionDisplay: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else {
            return version
        }
        return "\(version) (\(build))"
    }

    // MARK: - Private Properties

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let iCloudSyncService: ICloudSyncService
    @ObservationIgnored private let memoryStore: MemoryStore
    @ObservationIgnored private let logger: AppLogger
    @ObservationIgnored private let gitVersionService: GitVersionService
    @ObservationIgnored private let openAIClient: AIClient
    @ObservationIgnored private let selectionService: SelectionService
    @ObservationIgnored private let replaceService: ReplaceService
    @ObservationIgnored private let windowMoverService: WindowMoverService
    @ObservationIgnored private let iCloudPasswordsAutomationService: ICloudPasswordsAutomationService
    @ObservationIgnored private let inputSourceSwitchingService: InputSourceSwitchingService
    @ObservationIgnored private let hotKeyService: HotKeyService
    @ObservationIgnored private let resultPresenter: ResultPanelPresenter
    @ObservationIgnored private lazy var clipboardHistoryPresenter = ClipboardHistoryPanelPresenter(
        appModel: self,
        logger: logger
    )
    @ObservationIgnored private lazy var clipboardHistoryService = ClipboardHistoryService(
        makeRetention: { [weak self] in
            self?.settings.clipboardHistoryRetention ?? .oneMonth
        },
        onEntryCaptured: { [weak self] entry in
            self?.recordClipboardEntry(entry)
        }
    )

    @ObservationIgnored private var isBootstrapped = false
    @ObservationIgnored private var hasLoadedClipboardHistory = false
    @ObservationIgnored private var hasRecordedLaunchVersionMarker = false
    @ObservationIgnored private var lastPrunedRetention: ClipboardHistoryRetention?
    @ObservationIgnored private let clipboardHistoryPageSize = 100
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored private var lastExternalApplication: ExternalApplicationTarget?
    @ObservationIgnored private var lastClipboardHistoryApplication: ExternalApplicationTarget?
    @ObservationIgnored private var clipboardHistoryTargetApplication: ExternalApplicationTarget?
    @ObservationIgnored private var isApplyingICloudUpdate = false
    @ObservationIgnored private var activeCommandTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        let settingsStore = SettingsStore()
        let iCloudSyncService = ICloudSyncService()
        let memoryStore = MemoryStore()
        let logger = AppLogger.shared
        let gitVersionService = GitVersionService()
        self.settingsStore = settingsStore
        self.iCloudSyncService = iCloudSyncService
        self.memoryStore = memoryStore
        self.logger = logger
        self.gitVersionService = gitVersionService
        openAIClient = AIClient(logger: logger)
        selectionService = SelectionService(logger: logger)
        replaceService = ReplaceService(logger: logger)
        windowMoverService = WindowMoverService()
        let iCloudPasswordsAutomationService = ICloudPasswordsAutomationService(logger: logger)
        self.iCloudPasswordsAutomationService = iCloudPasswordsAutomationService
        let inputSourceSwitchingService = InputSourceSwitchingService(logger: logger)
        self.inputSourceSwitchingService = inputSourceSwitchingService
        hotKeyService = HotKeyService.shared
        resultPresenter = ResultPanelPresenter(logger: logger)
        iCloudPasswordsAutomationService.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.iCloudPasswordsAutomationStatus = status
                self?.diagnostics.iCloudPasswordsAutomationStatus = status.displayText
            }
        }
        inputSourceSwitchingService.onStatusChange = { [weak self] status in
            self?.inputSourceSwitchingStatus = status
            self?.diagnostics.inputSourceSwitchingStatus = status.displayText
        }
        inputSourceSwitchingService.onAvailableSourcesChange = { [weak self] sources in
            guard let self else { return }
            self.availableInputSources = sources
            self.automaticDefaultEnglishInputSource = self.inputSourceSwitchingService.automaticDefaultEnglishInputSource()
        }
        observeWorkspace()
        Task { await bootstrap() }
    }

    deinit {
        let service = inputSourceSwitchingService
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                service.stop()
            }
        } else {
            Task { @MainActor in
                service.stop()
            }
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    // MARK: - Public Methods

    // Bootstraps the application, loading settings and configuring hotkeys and background observers.
    func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        iCloudSyncService.refreshAvailability()
        if settingsStore.prefersICloudSync(),
           let settingsURL = iCloudSyncService.syncedURL(for: .settings) {
            iCloudSyncService.migrateLocalFilesIfNeeded()
            settingsStore.useSyncedFileURL(settingsURL)
        } else {
            settingsStore.useSyncedFileURL(nil)
        }
        settings = settingsStore.load(activeProviderOnly: true)
        normalizeCommandSettingsForCurrentProvider()
        if settingsStore.migrateCommandReasoningInheritance(in: &settings) {
            settingsStore.save(settings)
        }
        configureICloudSyncIfNeeded(migrate: false)
        lastPrunedRetention = settings.clipboardHistoryRetention
        memoryEntries = memoryStore.load().entries
        pruneMemoryEntriesIfNeeded()
        selectedCommandStableID = settings.commands.first?.id
        await logger.log("app", "Loaded settings", metadata: ["commands": "\(settings.commands.count)"])
        recomputeCommandIssues()
        reconfigureHotKeys()
        clipboardHistoryService.start()
        configureICloudPasswordsAutomation()
        configureInputSourceSwitching()
        refreshLightweightDiagnostics()
    }

    // Runs the specified command.
    func runCommand(_ command: AICommand, trigger: String) {
        guard !isExecuting else { return }
        activeCommandTask = Task { [weak self] in
            guard let self else { return }
            await self.performCommand(command, trigger: trigger)
        }
    }

    func cancelActiveCommand() {
        activeCommandTask?.cancel()
        activeCommandTask = nil
    }

    // Saves the application's settings.
    func saveSettings(reloadHotKeys: Bool = false) {
        settings.memoryLimit = AppSettings.normalizedMemoryLimit(settings.memoryLimit)
        normalizeCommandSettingsForCurrentProvider()
        configureICloudSyncIfNeeded()
        let snapshot = settings
        settingsStore.save(snapshot)
        pruneMemoryEntriesIfNeeded()
        memoryStore.save(MemoryStoreSnapshot(entries: memoryEntries))

        Task {
            await logger.log(
                "settings",
                "Saved settings",
                metadata: [
                    "commands": "\(snapshot.commands.count)",
                    "reload_hotkeys": "\(reloadHotKeys)",
                ]
            )
        }

        recomputeCommandIssues()
        if reloadHotKeys {
            reconfigureHotKeys()
        }

        refreshLightweightDiagnostics()

        if lastPrunedRetention != snapshot.clipboardHistoryRetention {
            lastPrunedRetention = snapshot.clipboardHistoryRetention
            Task {
                await clipboardHistoryService.prunePersistedEntries()
                if hasLoadedClipboardHistory {
                    await reloadClipboardHistory()
                }
            }
        }
    }

    // Restores the default commands.
    func restoreDefaultCommands() {
        settings.commands = AICommand.defaultCommands
        selectedCommandStableID = settings.commands.first?.id
        saveSettings(reloadHotKeys: true)
    }

    func setSyncWithICloud(_ isEnabled: Bool) {
        settings.syncWithICloud = isEnabled
        configureICloudSyncIfNeeded(migrate: isEnabled)
        saveSettings()
    }

    func setICloudPasswordsDiaAutomationEnabled(_ isEnabled: Bool) {
        settings.iCloudPasswordsDiaAutomationEnabled = isEnabled
        saveSettings()
        configureICloudPasswordsAutomation()
    }

    func configureInputSourceSwitching() {
        availableInputSources = inputSourceSwitchingService.availableInputSources()
        inputSourceSwitchingService.configure(
            enabled: settings.inputSourceSwitchingEnabled,
            defaultEnglishInputSourceID: settings.defaultEnglishInputSourceID,
            rules: settings.appInputSourceRules
        )
        automaticDefaultEnglishInputSource = inputSourceSwitchingService.automaticDefaultEnglishInputSource()
        inputSourceSwitchingStatus = inputSourceSwitchingService.currentStatus
        diagnostics.inputSourceSwitchingStatus = inputSourceSwitchingStatus.displayText
    }

    func refreshAvailableInputSources() {
        availableInputSources = inputSourceSwitchingService.availableInputSources(forceRefresh: true)
        automaticDefaultEnglishInputSource = inputSourceSwitchingService.automaticDefaultEnglishInputSource()
        if settings.inputSourceSwitchingEnabled {
            inputSourceSwitchingService.configure(
                enabled: settings.inputSourceSwitchingEnabled,
                defaultEnglishInputSourceID: settings.defaultEnglishInputSourceID,
                rules: settings.appInputSourceRules
            )
            automaticDefaultEnglishInputSource = inputSourceSwitchingService.automaticDefaultEnglishInputSource()
            inputSourceSwitchingStatus = inputSourceSwitchingService.currentStatus
            diagnostics.inputSourceSwitchingStatus = inputSourceSwitchingStatus.displayText
        }
    }

    func resolvedDefaultEnglishInputSource() -> KeyboardInputSource? {
        if availableInputSources.isEmpty {
            availableInputSources = inputSourceSwitchingService.availableInputSources()
        }
        return inputSourceSwitchingService.resolvedDefaultEnglishInputSource(
            preferredID: settings.defaultEnglishInputSourceID
        )
    }

    func preferredNonEnglishInputSourceID() -> String? {
        if availableInputSources.isEmpty {
            availableInputSources = inputSourceSwitchingService.availableInputSources()
        }
        let defaultEnglishID = resolvedDefaultEnglishInputSource()?.id
        if let nonASCIISource = availableInputSources.first(where: { !$0.isASCIICapable }) {
            return nonASCIISource.id
        }
        if let nonEnglishSource = availableInputSources.first(where: { source in
            source.id != defaultEnglishID &&
            !source.languages.contains(where: { $0 == "en" || $0.hasPrefix("en-") || $0.hasPrefix("en_") })
        }) {
            return nonEnglishSource.id
        }
        if let alternateSource = availableInputSources.first(where: { $0.id != defaultEnglishID }) {
            return alternateSource.id
        }
        return availableInputSources.first?.id
    }

    func setInputSourceSwitchingEnabled(_ enabled: Bool) {
        settings.inputSourceSwitchingEnabled = enabled
        saveSettings(reloadHotKeys: false)
        configureInputSourceSwitching()
        diagnostics.inputSourceSwitchingStatus = inputSourceSwitchingStatus.displayText
    }

    func setDefaultEnglishInputSourceID(_ id: String?) {
        settings.defaultEnglishInputSourceID = AppSettings.normalizedOptionalIdentifier(id)
        saveSettings(reloadHotKeys: false)
        configureInputSourceSwitching()
    }

    func upsertAppInputSourceRule(
        bundleIdentifier: String,
        appName: String,
        inputSourceID: String,
        isEnabled: Bool = true
    ) {
        guard let normalizedBundleID = AppSettings.normalizedOptionalIdentifier(bundleIdentifier),
              let normalizedInputSourceID = AppSettings.normalizedOptionalIdentifier(inputSourceID) else {
            return
        }
        let normalizedAppName = AppSettings.normalizedOptionalIdentifier(appName) ?? normalizedBundleID
        let updatedRule = AppInputSourceRule(
            bundleIdentifier: normalizedBundleID,
            appName: normalizedAppName,
            inputSourceID: normalizedInputSourceID,
            isEnabled: isEnabled
        )
        var rules = settings.appInputSourceRules
        if let existingIndex = rules.firstIndex(where: { $0.bundleIdentifier == normalizedBundleID }) {
            rules[existingIndex] = updatedRule
        } else {
            rules.append(updatedRule)
        }
        settings.appInputSourceRules = AppSettings.normalizedAppInputSourceRules(rules)
        saveSettings(reloadHotKeys: false)
        configureInputSourceSwitching()
    }

    func setAppInputSourceRuleEnabled(bundleIdentifier: String, isEnabled: Bool) {
        guard let normalizedBundleID = AppSettings.normalizedOptionalIdentifier(bundleIdentifier),
              let index = settings.appInputSourceRules.firstIndex(where: { $0.bundleIdentifier == normalizedBundleID }) else {
            return
        }
        settings.appInputSourceRules[index].isEnabled = isEnabled
        settings.appInputSourceRules = AppSettings.normalizedAppInputSourceRules(settings.appInputSourceRules)
        saveSettings(reloadHotKeys: false)
        configureInputSourceSwitching()
    }

    func removeAppInputSourceRule(bundleIdentifier: String) {
        guard let normalizedBundleID = AppSettings.normalizedOptionalIdentifier(bundleIdentifier) else {
            return
        }
        settings.appInputSourceRules.removeAll { $0.bundleIdentifier == normalizedBundleID }
        saveSettings(reloadHotKeys: false)
        configureInputSourceSwitching()
    }

    func saveClipboardImageToPhotos() {
        PhotoLibraryService.shared.saveImageFromClipboard()
    }

    func openSaveImageExtensionInstaller() {
        DiaImageExtensionService.shared.openExtensionInstaller()
    }

    // Adds a new command.
    func addCommand() {
        let nextIndex = settings.commands.count + 1
        let newCommand = AICommand.makeNew(index: nextIndex)
        settings.commands.append(newCommand)
        selectedSettingsSection = .commands
        selectedCommandStableID = newCommand.id
        saveSettings(reloadHotKeys: true)
    }

    // Moves commands within the settings list and persists the new order.
    func moveCommand(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        let movingCommands = source.map { settings.commands[$0] }
        for index in source.sorted(by: >) {
            settings.commands.remove(at: index)
        }

        let removalCountBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - removalCountBeforeDestination, settings.commands.count))
        settings.commands.insert(contentsOf: movingCommands, at: adjustedDestination)
        saveSettings(reloadHotKeys: true)
    }

    // Deletes the selected command.
    func deleteSelectedCommand() {
        guard let selectedCommandStableID,
              let index = settings.commands.firstIndex(where: { $0.id == selectedCommandStableID }) else {
            return
        }

        settings.commands.remove(at: index)
        self.selectedCommandStableID = settings.commands.indices.contains(index)
            ? settings.commands[index].id
            : settings.commands.last?.id
        saveSettings(reloadHotKeys: true)
    }

    // Prompts the user for Accessibility permissions.
    func promptForAccessibilityPermission() {
        _ = selectionService.isAccessibilityTrusted(prompt: true)
        Task {
            await logger.log("permissions", "Prompted for accessibility permission")
            await refreshDiagnostics()
        }
    }

    private func configureICloudPasswordsAutomation() {
        if settings.iCloudPasswordsDiaAutomationEnabled {
            iCloudPasswordsAutomationService.start()
        } else {
            iCloudPasswordsAutomationService.stop()
        }
    }

    // Opens the Accessibility settings in System Preferences.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func moveFocusedWindowToNextMonitor() {
        do {
            let result = try windowMoverService.moveFocusedWindowToNextScreen()
            Task {
                await logger.log(
                    "window",
                    "Moved focused window to next monitor",
                    metadata: [
                        "app": result.applicationName,
                        "source_monitor": result.sourceScreenName,
                        "target_monitor": result.targetScreenName,
                    ]
                )
            }
        } catch {
            Task {
                await logger.log(
                    "window",
                    "Failed to move focused window",
                    metadata: ["error": error.localizedDescription]
                )
            }

            if case WindowMoverError.accessibilityPermissionMissing = error {
                promptForAccessibilityPermission()
            }
        }
    }

    // Prepares the application for window presentation.
    func prepareForAppWindowPresentation() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    // Finalizes the window presentation.
    func finalizeWindowPresentation(matchingTitle title: String) {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        let matchingWindow = NSApp.windows.first { window in
            window.title.localizedCaseInsensitiveContains(title)
        }
        matchingWindow?.makeKeyAndOrderFront(nil)
        matchingWindow?.orderFrontRegardless()
    }

    // Records native window lifecycle events and disables tracking for hidden windows.
    func updateWindowLifecycle(named name: String, isVisible: Bool) {
        let matchingWindows = NSApp.windows.filter { window in
            window.title.localizedCaseInsensitiveContains(name)
        }

        for window in matchingWindows {
            window.ignoresMouseEvents = !isVisible
            if !isVisible {
                window.acceptsMouseMovedEvents = false
            }
        }

        let retainedWindowCount = NSApp.windows.count
        let visibleWindowCount = NSApp.windows.filter(\.isVisible).count
        Task {
            await logger.log(
                "window",
                isVisible ? "Presented application window" : "Cleaned up hidden application window",
                metadata: [
                    "matching_windows": "\(matchingWindows.count)",
                    "name": name,
                    "retained_windows": "\(retainedWindowCount)",
                    "visible_windows": "\(visibleWindowCount)",
                ]
            )
        }
    }

    func revealLogFile() {
        let logURL = diagnostics.logFilePath.isEmpty ? nil : URL(fileURLWithPath: diagnostics.logFilePath)
        guard let logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    // Reveals the version log file in the Finder.
    func revealVersionLogFile() {
        let logURL = diagnostics.versionLogFilePath.isEmpty ? nil : URL(fileURLWithPath: diagnostics.versionLogFilePath)
        guard let logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    // Reveals the repository in the Finder.
    func revealRepository() {
        let repositoryURL = diagnostics.gitVersion.repositoryPath.isEmpty ? nil : URL(fileURLWithPath: diagnostics.gitVersion.repositoryPath)
        guard let repositoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repositoryURL])
    }

    // Copies the specified text to the clipboard.
    func copyResultToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        clipboardHistoryService.captureCurrentClipboard()

        Task {
            await logger.log("popup", "Copied result to clipboard", metadata: ["length": "\(text.count)"])
        }
    }

    func clearMemory() {
        memoryEntries.removeAll()
        memoryStore.save(MemoryStoreSnapshot(entries: []))
        Task {
            await logger.log("memory", "Cleared AI memory")
        }
    }

    func addMemory(title: String, summary: String, source: AIMemorySource = .command) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedSummary.isEmpty else { return }

        upsertMemory(
            AIMemoryEntry(
                source: source,
                title: trimmedTitle,
                summary: trimmedSummary,
                relatedID: "manual-\(UUID().uuidString)"
            )
        )
        Task {
            await logger.log("memory", "Added manual AI memory", metadata: ["source": source.rawValue])
        }
    }

    func updateMemory(_ memory: AIMemoryEntry, title: String, summary: String, source: AIMemorySource) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedSummary.isEmpty,
              let index = memoryEntries.firstIndex(where: { $0.id == memory.id }) else {
            return
        }

        memoryEntries[index].title = trimmedTitle
        memoryEntries[index].summary = trimmedSummary
        memoryEntries[index].source = source
        memoryEntries[index].updatedAt = Date()
        persistMemoryEntries()
        Task {
            await logger.log("memory", "Updated AI memory", metadata: ["source": source.rawValue])
        }
    }

    func deleteMemory(id: UUID) {
        memoryEntries.removeAll { $0.id == id }
        persistMemoryEntries()
        Task {
            await logger.log("memory", "Deleted AI memory")
        }
    }

    func ensureCredentialsLoaded(for provider: AIProvider) {
        settingsStore.ensureCredentialsLoaded(for: provider, in: &settings)
    }

    func selectProvider(_ provider: AIProvider) {
        guard provider != settings.provider else { return }
        ensureCredentialsLoaded(for: provider)
        settings.provider = provider
        settings.defaultModel = settings.defaultModel(for: provider)
        saveSettings()
        if provider == .openRouter, modelCapabilities[provider.rawValue] == nil {
            refreshProviderModels(provider)
        }
    }

    func refreshProviderModels(_ provider: AIProvider) {
        let providerID = provider.rawValue
        guard !refreshingModelProviders.contains(providerID) else { return }
        ensureCredentialsLoaded(for: provider)
        let baseURL: String
        let apiKey: String
        switch provider {
        case .openAICompatible: (baseURL, apiKey) = (settings.apiBaseURL, settings.apiKey)
        case .openRouter: (baseURL, apiKey) = (settings.openRouterBaseURL, settings.openRouterAPIKey)
        case .deepSeek: (baseURL, apiKey) = (settings.deepSeekBaseURL, settings.deepSeekAPIKey)
        }
        refreshingModelProviders.insert(providerID)
        modelCatalogStatus[providerID] = "Loading models…"
        Task {
            defer { refreshingModelProviders.remove(providerID) }
            do {
                let catalog = try await ProviderModelCatalog.fetch(provider: provider, baseURL: baseURL, apiKey: apiKey)
                let currentURL: String
                let currentKey: String
                switch provider {
                case .openAICompatible: (currentURL, currentKey) = (settings.apiBaseURL, settings.apiKey)
                case .openRouter: (currentURL, currentKey) = (settings.openRouterBaseURL, settings.openRouterAPIKey)
                case .deepSeek: (currentURL, currentKey) = (settings.deepSeekBaseURL, settings.deepSeekAPIKey)
                }
                guard currentURL == baseURL, currentKey == apiKey else {
                    modelCatalogStatus[providerID] = "Connection changed. Refresh models again."
                    return
                }
                let models = AppSettings.normalizedModels(catalog.data.map(\.id)).sorted()
                discoveredModels[providerID] = models
                var capabilities: [String: OpenRouterReasoningCapability] = [:]
                for model in catalog.data {
                    if let reasoning = model.reasoning { capabilities[model.id] = reasoning }
                    else if let levels = model.effort?.supported_levels {
                        capabilities[model.id] = .init(supportedEfforts: levels)
                    }
                }
                modelCapabilities[providerID] = capabilities
                if provider == .openAICompatible {
                    await refreshVerifiedReasoningCapabilities(models: models, baseURL: baseURL, apiKey: apiKey)
                }
                if provider == .openRouter { openRouterReasoningCapabilities = capabilities }
                modelCatalogStatus[providerID] = "Loaded \(models.count) models. Select Add to make a model available in commands."
            } catch {
                modelCatalogStatus[providerID] = error.localizedDescription
            }
        }
    }

    private func refreshVerifiedReasoningCapabilities(models: [String], baseURL: String, apiKey: String) async {
        let providerID = AIProvider.openAICompatible.rawValue
        let bundled = localVerifiedReasoningCapabilities
        var didUpdateSettings = false
        var didUpdateLocalCache = false
        for model in models {
            if settings.verifiedReasoningCapabilities[providerID]?[model]?.isFresh(for: baseURL) != true,
               let entry = bundled[model], entry.isFresh(for: baseURL) {
                settings.verifiedReasoningCapabilities[providerID, default: [:]][model] = entry
                didUpdateSettings = true
            }
        }
        let missing = models.filter {
            modelCapabilities[providerID]?[$0]?.supportedEfforts == nil && settings.verifiedReasoningCapabilities[providerID]?[$0]?.isFresh(for: baseURL) != true
        }
        defer {
            if didUpdateLocalCache {
                VerifiedReasoningCapability.store(localVerifiedReasoningCapabilities)
            }
            if didUpdateSettings {
                saveSettings()
            }
        }
        if !missing.isEmpty {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            for (index, model) in missing.enumerated() {
                guard settings.apiBaseURL == baseURL, settings.apiKey == apiKey else { return }
                modelCatalogStatus[providerID] = "Checking reasoning \(index + 1)/\(missing.count): \(model)"
                let capability = await ReasoningCapabilityDiscovery.discover(model: model, baseURL: baseURL, apiKey: key)
                guard settings.apiBaseURL == baseURL, settings.apiKey == apiKey else { return }
                settings.verifiedReasoningCapabilities[providerID, default: [:]][model] = capability
                localVerifiedReasoningCapabilities[model] = capability
                didUpdateLocalCache = true
                didUpdateSettings = true
            }
        }
    }

    func verifiedReasoningCapability(for model: String, provider: AIProvider) -> VerifiedReasoningCapability? {
        guard provider == .openAICompatible else { return nil }
        let candidates = [settings.verifiedReasoningCapabilities[provider.rawValue]?[model], localVerifiedReasoningCapabilities[model]]
        return candidates.compactMap { $0 }.first { $0.isFresh(for: settings.apiBaseURL) }
    }

    func availableReasoningModes(for model: String, provider: AIProvider? = nil) -> [ReasoningMode] {
        let provider = provider ?? settings.provider
        let verified = verifiedReasoningCapability(for: model, provider: provider)
        let reported = modelCapabilities[provider.rawValue]?[model]
        let capability = reported?.supportedEfforts != nil ? reported
            : verified.map { OpenRouterReasoningCapability(supportedEfforts: $0.efforts.map(\.rawValue)) } ?? reported
        return ModelReasoning.modes(
            provider: provider,
            model: model,
            capability: capability,
            manualEfforts: settings.manualReasoningEfforts(for: model, provider: provider)
        )
    }

    func setManualReasoningEfforts(_ efforts: [ReasoningMode]?, for model: String, provider: AIProvider) {
        settings.setManualReasoningEfforts(efforts, for: model, provider: provider)
        saveSettings()
    }

    func defaultReasoningMode(for model: String) -> ReasoningMode {
        settings.defaultReasoningMode(for: model, provider: settings.provider, availableModes: availableReasoningModes(for: model))
    }

    func selectDefaultReasoning(_ mode: ReasoningMode) {
        let model = settings.defaultModel
        guard availableReasoningModes(for: model).contains(mode) else { return }
        settings.setDefaultReasoningMode(mode, for: model, provider: settings.provider)
        saveSettings()
    }

    func commandReasoningMode(for command: AICommand, model: String) -> ReasoningMode {
        if command.useDefaultReasoning { return defaultReasoningMode(for: model) }
        return availableReasoningModes(for: model).contains(command.reasoningMode) ? command.reasoningMode : .modelDefault
    }

    func addProviderModel(_ model: String, for provider: AIProvider) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        updateModelCatalog(settings.modelCatalog(for: provider) + [trimmedModel], for: provider)
    }

    func removeProviderModel(_ model: String, for provider: AIProvider) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = settings.modelCatalog(for: provider)
        guard catalog.count > 1, catalog.contains(trimmedModel) else {
            return
        }
        updateModelCatalog(catalog.filter { $0 != trimmedModel }, for: provider)
    }

    func resetProviderModelCatalog(for provider: AIProvider) {
        updateModelCatalog(AppSettings.modelCatalog(for: provider), for: provider)
    }

    private func normalizeCommandSettingsForCurrentProvider() {
        normalizeCommandSettingsForCurrentProvider(&settings)
    }

    private func normalizeCommandSettingsForCurrentProvider(_ candidate: inout AppSettings) {
        candidate.providerDefaultModels = AppSettings.normalizedProviderDefaultModels(
            candidate.providerDefaultModels,
            selectedProvider: candidate.provider,
            selectedDefaultModel: candidate.defaultModel,
            providerModelCatalogs: candidate.providerModelCatalogs
        )
        candidate.defaultModel = candidate.defaultModel(for: candidate.provider)
    }

    private func updateModelCatalog(_ models: [String], for provider: AIProvider) {
        let previousCatalog = settings.modelCatalog(for: provider)
        let updatedCatalog = AppSettings.normalizedModels(models)
        guard !updatedCatalog.isEmpty, updatedCatalog != previousCatalog else { return }

        settings.providerModelCatalogs[provider.rawValue] = updatedCatalog
        settings.providerModelCatalogs = AppSettings.normalizedProviderModelCatalogs(settings.providerModelCatalogs)
        settings.setDefaultModel(settings.defaultModel(for: provider), for: provider)
        saveSettings()
    }

    private func configureICloudSyncIfNeeded(migrate: Bool = true) {
        iCloudSyncService.refreshAvailability()
        guard settings.syncWithICloud,
              let settingsURL = iCloudSyncService.syncedURL(for: .settings) else {
            settingsStore.useSyncedFileURL(nil)
            iCloudSyncService.stopObserving()
            return
        }

        if migrate {
            iCloudSyncService.migrateLocalFilesIfNeeded()
        }
        settingsStore.useSyncedFileURL(settingsURL)
        iCloudSyncService.startObserving { [weak self] changedFiles in
            self?.applyICloudChanges(changedFiles)
        }
    }

    private func applyICloudChanges(_ changedFiles: Set<ICloudSyncFile>) {
        guard settings.syncWithICloud, !isApplyingICloudUpdate else { return }
        isApplyingICloudUpdate = true
        defer { isApplyingICloudUpdate = false }
        var appliedFiles = Set<ICloudSyncFile>()

        if changedFiles.contains(.settings) {
            let previousSyncSetting = settings.syncWithICloud
            let previousDefaultEnglishID = settings.defaultEnglishInputSourceID
            let previousAppRules = settings.appInputSourceRules
            var updatedSettings = settingsStore.load(activeProviderOnly: true)
            updatedSettings.syncWithICloud = previousSyncSetting
            normalizeCommandSettingsForCurrentProvider(&updatedSettings)

            if updatedSettings != settings {
                settings = updatedSettings
                pruneMemoryEntriesIfNeeded()
                recomputeCommandIssues()
                reconfigureHotKeys()
                if settings.defaultEnglishInputSourceID != previousDefaultEnglishID ||
                    settings.appInputSourceRules != previousAppRules {
                    configureInputSourceSwitching()
                }
                appliedFiles.insert(.settings)
            }
        }

        guard !appliedFiles.isEmpty else { return }
        refreshLightweightDiagnostics()
        Task {
            await logger.log(
                "icloud",
                "Applied synced file changes",
                metadata: ["files": appliedFiles.map(\.fileName).sorted().joined(separator: ",")]
            )
        }
    }

    func restoreClipboardEntry(_ entry: ClipboardHistoryEntry) {
        restoreClipboardForHistoryEntry(entry)
        Task {
            await promoteClipboardEntryToTop(entry, reason: "restore")
            await logger.log(
                "clipboard",
                "Restored clipboard history entry",
                metadata: [
                    "type": entry.contentType.rawValue,
                    "source_app": entry.sourceAppName,
                ]
            )
        }
    }

    func restoreClipboardEntry(id: UUID) {
        Task {
            guard let entry = await clipboardHistoryService.loadPersistedEntry(id: id) else { return }
            await MainActor.run {
                self.selectedClipboardEntryDetail = entry
                self.restoreClipboardEntry(entry)
            }
        }
    }

    func selectClipboardEntry(id: UUID?) {
        let previousID = selectedClipboardEntryID
        guard selectedClipboardEntryID != id else { return }
        selectedClipboardEntryID = id
        logClipboardHistoryNavigation(
            "Selected clipboard history entry",
            metadata: [
                "previous_id": previousID?.uuidString ?? "nil",
                "selected_id": id?.uuidString ?? "nil",
            ]
        )
        Task {
            await loadSelectedClipboardEntryIfNeeded()
        }
    }

    func logClipboardHistoryNavigation(_ message: String, metadata: [String: String] = [:]) {
        Task {
            await logger.log("clipboard-navigation", message, metadata: metadata)
        }
    }

    func pasteClipboardEntryToSelection(_ entry: ClipboardHistoryEntry) {
        Task {
            do {
                let target = try resolveClipboardHistoryTargetApplication()
                restoreClipboardForHistoryEntry(entry)
                try await replaceService.pasteCurrentClipboard(into: target)
                await promoteClipboardEntryToTop(entry, reason: "paste")
            } catch {
                await logger.log(
                    "clipboard",
                    "Paste from clipboard history failed",
                    metadata: [
                        "error": error.localizedDescription,
                    ]
                )
                presentErrorAlert(title: "Paste Failed", error: error)
            }
        }
    }

    private func restoreClipboardForHistoryEntry(_ entry: ClipboardHistoryEntry) {
        switch entry.contentType {
        case .text, .link:
            guard let plainText = entry.plainText else {
                clipboardHistoryService.ignoreNextCapture(for: entry.fingerprint)
                entry.snapshot.restore(to: .general)
                return
            }
            clipboardHistoryService.ignoreNextCapture()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(plainText, forType: .string)
        case .all, .file, .image, .other:
            clipboardHistoryService.ignoreNextCapture(for: entry.fingerprint)
            entry.snapshot.restore(to: .general)
        }
    }

    func pasteClipboardEntryToSelection(id: UUID) {
        Task {
            guard let entry = await clipboardHistoryService.loadPersistedEntry(id: id) else { return }
            await MainActor.run {
                self.selectedClipboardEntryDetail = entry
                self.pasteClipboardEntryToSelection(entry)
            }
        }
    }

    func clearClipboardHistory() {
        clipboardHistoryEntries.removeAll()
        selectedClipboardEntryID = nil
        selectedClipboardEntryDetail = nil
        hasMoreClipboardHistoryEntries = false
        Task {
            await clipboardHistoryService.clear()
        }
    }

    func loadClipboardHistoryIfNeeded() async {
        guard !hasLoadedClipboardHistory else { return }
        await reloadClipboardHistory(resetSelection: true)
    }

    func pruneClipboardHistoryForCurrentRetention() {
        lastPrunedRetention = settings.clipboardHistoryRetention
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.clipboardHistoryService.prunePersistedEntries()
            await self.reloadClipboardHistory(resetSelection: true)
        }
    }

    func loadMoreClipboardHistoryEntriesIfNeeded(currentEntryID: UUID?) {
        guard hasMoreClipboardHistoryEntries else { return }
        guard let currentEntryID else {
            Task { await loadMoreClipboardHistoryEntries() }
            return
        }
        guard clipboardHistoryEntries.suffix(10).contains(where: { $0.id == currentEntryID }) else { return }
        Task { await loadMoreClipboardHistoryEntries() }
    }

    func updateClipboardHistoryQuery(searchText: String, filter: ClipboardContentType) {
        guard clipboardHistorySearchText != searchText || clipboardHistorySelectedFilter != filter else { return }
        clipboardHistorySearchText = searchText
        clipboardHistorySelectedFilter = filter
        Task {
            await reloadClipboardHistory(resetSelection: true)
        }
    }

    func requestOpenClipboardHistoryWindow() {
        selectedClipboardEntryID = clipboardHistoryEntries.first?.id
        selectedClipboardEntryDetail = nil

        // Update the token so the SwiftUI menu-bar path (MenuBarLabelView)
        // can also react if needed, but now we ALSO drive the panel directly
        // so the window appears even when another app is in full-screen mode.
        clipboardHistoryTargetApplication = preferredClipboardHistoryTargetApplication()
        clipboardHistoryOpenRequestToken = UUID()
        Task {
            await reloadClipboardHistory(resetSelection: true)
        }
        clipboardHistoryPresenter.show()
    }

    var selectedClipboardEntry: ClipboardHistoryEntry? {
        guard let selectedClipboardEntryID else {
            return selectedClipboardEntryDetail?.id == clipboardHistoryEntries.first?.id ? selectedClipboardEntryDetail : nil
        }
        guard selectedClipboardEntryDetail?.id == selectedClipboardEntryID else { return nil }
        return selectedClipboardEntryDetail
    }

    // Replaces the current selection with the specified text.
    func replaceSelection(using result: CommandExecutionResult) {
        Task {
            do {
                copyResultToClipboard(result.output)
                try await replaceService.replaceSelectedText(
                    with: result.output,
                    in: result.target,
                    restoreAnchor: result.selectionRestoreAnchor
                )
            } catch {
                await logger.log("replace", "Replace failed", metadata: ["error": error.localizedDescription])
                presentErrorAlert(title: "Replace Failed", error: error)
            }
        }
    }

    // Replaces the current selection when possible, otherwise keeps the result available on the clipboard.
    func replaceSelectionOrCopyResult(using result: CommandExecutionResult) {
        Task {
            copyResultToClipboard(result.output)
            do {
                try await replaceService.replaceSelectedText(
                    with: result.output,
                    in: result.target,
                    restoreAnchor: result.selectionRestoreAnchor
                )
            } catch {
                await logger.log(
                    "replace",
                    "Replace failed; result remains on clipboard",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func commandRequestMessages(
        prompt: String,
        selectionText: String,
        command: AICommand
    ) -> [AIClientMessage] {
        var messages: [AIClientMessage] = []
        if let memoryContext = memoryContext(for: "\(command.title)\n\(selectionText)", source: .command) {
            messages.append(AIClientMessage(role: "system", content: memoryContext))
        }
        messages.append(AIClientMessage(role: "user", content: prompt))
        return messages
    }

    private func memoryContext(for text: String, source: AIMemorySource) -> String? {
        guard settings.memoryEnabled else { return nil }
        let relatedMemories = relevantMemoryEntries(for: text, source: source, limit: 6)
        guard !relatedMemories.isEmpty else { return nil }

        let memoryLines = relatedMemories.map { memory in
            "- [\(memory.source.rawValue)] \(memory.title): \(memory.summary)"
        }.joined(separator: "\n")

        return """
        Use these local daydream memories only when they are relevant. Do not mention them unless helpful.
        \(memoryLines)
        """
    }

    private func relevantMemoryEntries(
        for text: String,
        source: AIMemorySource,
        limit: Int
    ) -> [AIMemoryEntry] {
        let queryTokens = memoryTokens(from: text)
        let scoredEntries = memoryEntries.map { entry -> (entry: AIMemoryEntry, score: Int) in
            let entryTokens = memoryTokens(from: "\(entry.title) \(entry.summary)")
            let overlap = queryTokens.intersection(entryTokens).count
            let sourceBonus = entry.source == source ? 2 : 0
            let recencyBonus = Calendar.current.dateComponents([.day], from: entry.updatedAt, to: Date()).day.map { max(0, 5 - $0) } ?? 0
            return (entry, overlap + recencyBonus + sourceBonus)
        }

        return scoredEntries
            .filter { $0.score > 0 }
            .sorted {
                if $0.score == $1.score {
                    return $0.entry.updatedAt > $1.entry.updatedAt
                }
                return $0.score > $1.score
            }
            .prefix(limit)
            .map(\.entry)
    }

    private func memoryTokens(from text: String) -> Set<String> {
        MemoryTokenizer.tokens(from: text)
    }

    private func rememberInteraction(
        source: AIMemorySource,
        title: String,
        userText: String,
        assistantText: String,
        relatedID: String,
        model: String
    ) async {
        guard settings.memoryEnabled else { return }
        let combinedLength = userText.count + assistantText.count
        guard combinedLength >= 80 else { return }
        ensureCredentialsLoaded(for: settings.provider)

        do {
            let summary = try await openAIClient.generateText(
                provider: settings.provider,
                openAICompatibleBaseURL: settings.apiBaseURL,
                openAICompatibleAPIKey: settings.apiKey,
                openRouterBaseURL: settings.openRouterBaseURL,
                openRouterAPIKey: settings.openRouterAPIKey,
                deepSeekBaseURL: settings.deepSeekBaseURL,
                deepSeekAPIKey: settings.deepSeekAPIKey,
                model: model,
                messages: [
                    AIClientMessage(
                        role: "system",
                        content: "Extract durable user preferences, project facts, writing style, and recurring context from this interaction. Return one concise memory under 60 words. Return an empty string if there is nothing worth remembering."
                    ),
                    AIClientMessage(
                        role: "user",
                        content: """
                        Source: \(source.rawValue)
                        Title: \(title)

                        User/input:
                        \(String(userText.prefix(4000)))

                        Assistant/output:
                        \(String(assistantText.prefix(4000)))
                        """
                    )
                ]
            )
            let cleanedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedSummary.isEmpty else { return }
            upsertMemory(
                AIMemoryEntry(
                    source: source,
                    title: title,
                    summary: String(cleanedSummary.prefix(600)),
                    relatedID: relatedID
                )
            )
            await logger.log("memory", "Saved AI memory", metadata: ["source": source.rawValue])
        } catch {
            await logger.log("memory", "Memory extraction failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func upsertMemory(_ entry: AIMemoryEntry) {
        if let index = memoryEntries.firstIndex(where: { $0.relatedID == entry.relatedID && $0.source == entry.source }) {
            memoryEntries[index].title = entry.title
            memoryEntries[index].summary = entry.summary
            memoryEntries[index].updatedAt = Date()
        } else {
            memoryEntries.insert(entry, at: 0)
        }
        persistMemoryEntries()
    }

    private func persistMemoryEntries() {
        pruneMemoryEntriesIfNeeded()
        memoryEntries.sort { $0.updatedAt > $1.updatedAt }
        memoryStore.save(MemoryStoreSnapshot(entries: memoryEntries))
    }

    private func pruneMemoryEntriesIfNeeded() {
        let limit = AppSettings.normalizedMemoryLimit(settings.memoryLimit)
        settings.memoryLimit = limit
        guard memoryEntries.count > limit else { return }
        memoryEntries = Array(memoryEntries.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private func refreshLightweightDiagnostics() {
        diagnostics.accessibilityTrusted = selectionService.isAccessibilityTrusted()
        diagnostics.iCloudPasswordsAutomationStatus = iCloudPasswordsAutomationStatus.displayText
        diagnostics.inputSourceSwitchingStatus = inputSourceSwitchingStatus.displayText
        diagnostics.logFilePath = logger.logFileURL.path
        diagnostics.versionLogFilePath = gitVersionService.versionLogFileURL.path
        diagnostics.settingsFilePath = settingsStore.fileURL.path
        diagnostics.iCloudSyncAvailable = iCloudSyncService.isAvailable
        diagnostics.iCloudSyncDirectoryPath = iCloudSyncService.iCloudDirectory?.path ?? ""
        diagnostics.registeredHotKeys = settings.commands.compactMap { command in
            guard let shortcut = command.shortcut else { return nil }
            return "\(command.title)  \(shortcut.displayString)"
        }
        if let shortcut = settings.clipboardHistoryShortcut {
            diagnostics.registeredHotKeys.append("Clipboard History  \(shortcut.displayString)")
        }

        diagnostics.registeredHotKeys.append("Move Window to Next Monitor  \(settings.moveWindowShortcut.displayString)")
        diagnostics.hotKeyIssues = hotKeyIssues
        diagnostics.lastExternalApp = lastExternalApplication?.displayName ?? "Unknown"
    }

    // Refreshes the application's diagnostics.
    func refreshDiagnostics() async {
        refreshLightweightDiagnostics()
        diagnostics.logText = await logger.readLogTail()
        let gitSnapshot = await gitVersionService.captureSnapshot()
        if !hasRecordedLaunchVersionMarker {
            hasRecordedLaunchVersionMarker = true
            await gitVersionService.recordVersionMarker(reason: "launch", snapshot: gitSnapshot)
        }
        diagnostics.versionLogText = await gitVersionService.readVersionLogTail()
        diagnostics.gitVersion = gitSnapshot
        diagnostics.gitCommitHistory = await gitVersionService.captureCommitHistory()
    }

    // MARK: - Private Methods

    // Performs the specified command.
    private func performCommand(_ command: AICommand, trigger: String) async {
        guard !isExecuting else { return }
        isExecuting = true
        executingCommandID = command.id
        executingCommandTitle = command.title
        let started = ContinuousClock.now
        var pendingResultID: UUID?
        func elapsedMilliseconds() -> String {
            let duration = started.duration(to: .now).components
            return String(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
        }
        defer {
            isExecuting = false
            executingCommandID = nil
            executingCommandTitle = nil
            activeCommandTask = nil
        }

        do {
            let target = try resolveTargetApplication(trigger: trigger)
            ensureCredentialsLoaded(for: settings.provider)
            let requestSettings = settings
            let model = command.effectiveModel(defaultModel: requestSettings.defaultModel)
            let reasoningMode = commandReasoningMode(for: command, model: model)
            await logger.log("command", "Triggered command", metadata: [
                "command_id": command.commandID,
                "title": command.title,
                "trigger": trigger,
                "target_app": target.displayName,
                "target_bundle_id": target.bundleIdentifier ?? "nil",
                "target_resolution": targetResolutionDescription(for: trigger, resolved: target),
                "reasoning": reasoningMode.rawValue,
            ])

            var result = CommandExecutionResult(
                commandTitle: command.title, model: model, output: "", originalSelection: "",
                captureSource: .accessibility, target: target, commandID: command.commandID,
                selectionRestoreAnchor: nil
            )
            let popupState = ResultPopupState(result: result, isStreaming: true)
            popupState.statusMessage = "Reading selection…"
            if command.showPopup {
                pendingResultID = result.id
                // Keep keyboard focus in the source application until selection capture finishes.
                resultPresenter.show(state: popupState, takeFocus: false, onApply: { [weak self] in
                    self?.replaceSelectionOrCopyResult(using: popupState.result)
                }, onClose: { [weak self] in
                    if popupState.isStreaming {
                        self?.cancelActiveCommand()
                    }
                    Task { await self?.logger.log("popup", "Closed result popup", metadata: ["command": command.title]) }
                })
                await logger.log("popup", "Showing processing result popup", metadata: [
                    "command": command.title, "elapsed_ms": elapsedMilliseconds(),
                ])
            }

            let selection = try await selectionService.captureSelection(for: target)
            try Task.checkCancellation()
            guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.emptySelection }
            result.originalSelection = selection.text
            result.captureSource = selection.source
            result.selectionRestoreAnchor = selection.restoreAnchor
            popupState.result = result
            popupState.statusMessage = "Waiting for model…"
            if command.showPopup { resultPresenter.focusIfVisible(resultID: result.id) }
            await logger.log("command", "Selection ready", metadata: ["elapsed_ms": elapsedMilliseconds()])

            let preCommandClipboard = NSPasteboard.general.string(forType: .string) ?? ""
            let prompt = command.renderPrompt(
                with: selection.text,
                appName: target.displayName,
                clipboardText: preCommandClipboard
            )
            let requestMessages = commandRequestMessages(prompt: prompt, selectionText: selection.text, command: command)
            var output = ""
            var lastPopupUpdate = Date.distantPast
            var receivedFirstOutput = false
            for try await delta in openAIClient.streamText(
                provider: requestSettings.provider,
                openAICompatibleBaseURL: requestSettings.apiBaseURL,
                openAICompatibleAPIKey: requestSettings.apiKey,
                openRouterBaseURL: requestSettings.openRouterBaseURL,
                openRouterAPIKey: requestSettings.openRouterAPIKey,
                deepSeekBaseURL: requestSettings.deepSeekBaseURL,
                deepSeekAPIKey: requestSettings.deepSeekAPIKey,
                model: model, messages: requestMessages, reasoningMode: reasoningMode
            ) {
                try Task.checkCancellation()
                output += delta
                let now = Date()
                if command.showPopup, now.timeIntervalSince(lastPopupUpdate) >= 0.16 {
                    result.output = output
                    popupState.result = result
                    popupState.statusMessage = "Generating…"
                    lastPopupUpdate = now
                }
                if !receivedFirstOutput {
                    receivedFirstOutput = true
                    await logger.log("command", "Received first visible output", metadata: ["elapsed_ms": elapsedMilliseconds()])
                }
            }
            try Task.checkCancellation()
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw AppError.noResponseText }
            result.output = output
            popupState.result = result
            popupState.isStreaming = false
            copyResultToClipboard(output)
            if command.saveToObsidian {
                try saveCommandOutputToObsidian(output, title: selection.text, settings: requestSettings)
            }
            await logger.log("command", "Completed command", metadata: [
                "command_id": command.commandID, "title": command.title,
                "capture_source": selection.source.rawValue, "output_length": "\(output.count)",
                "saved_to_obsidian": "\(command.saveToObsidian)", "elapsed_ms": elapsedMilliseconds(),
            ])
            if !command.showPopup { await logger.log("popup", "Command popup disabled", metadata: ["command": command.title]) }
            Task {
                await self.rememberInteraction(source: .command, title: command.title, userText: selection.text,
                    assistantText: output, relatedID: command.commandID, model: model)
            }
        } catch is CancellationError {
            if let pendingResultID { resultPresenter.close(reason: "command_cancelled", resultID: pendingResultID) }
            await logger.log("command", "Command cancelled", metadata: ["command_id": command.commandID, "elapsed_ms": elapsedMilliseconds()])
        } catch let urlError as URLError where urlError.code == .cancelled {
            if let pendingResultID { resultPresenter.close(reason: "command_cancelled", resultID: pendingResultID) }
            await logger.log("command", "Command cancelled", metadata: ["command_id": command.commandID, "elapsed_ms": elapsedMilliseconds()])
        } catch {
            if Task.isCancelled {
                if let pendingResultID { resultPresenter.close(reason: "command_cancelled", resultID: pendingResultID) }
                await logger.log("command", "Command cancelled", metadata: ["command_id": command.commandID, "elapsed_ms": elapsedMilliseconds()])
                return
            }
            if let pendingResultID { resultPresenter.close(reason: "command_error", resultID: pendingResultID) }
            await logger.log("command", "Command failed", metadata: ["error": error.localizedDescription, "elapsed_ms": elapsedMilliseconds()])
            presentErrorAlert(title: "Command Failed", error: error)
        }
    }

    private func saveCommandOutputToObsidian(_ output: String, title: String, settings: AppSettings) throws {
        if let writtenFileURL = try ObsidianNoteService.writeNoteSilentlyIfPossible(
            content: output,
            selectedText: title,
            vaultName: settings.obsidianVaultName,
            subfolder: settings.obsidianSubfolder
        ) {
            Task {
                await logger.log("obsidian", "Saved note directly to local vault", metadata: ["path": writtenFileURL.path])
            }
            return
        }

        guard let url = ObsidianNoteService.fallbackObsidianURL(
            content: output,
            selectedText: title,
            vaultName: settings.obsidianVaultName,
            subfolder: settings.obsidianSubfolder
        ) else {
            throw AppError.skillExecutionFailed("Could not build Obsidian note URL.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { [logger] _, error in
            if let error {
                Task {
                    await logger.log("obsidian", "Fallback obsidian:// open failed", metadata: ["error": error.localizedDescription])
                }
            }
        }
    }

    // Resolves the target application for a command.
    private func resolveTargetApplication(trigger: String) throws -> ExternalApplicationTarget {
        let frontmost = NSWorkspace.shared.frontmostApplication

        if trigger == "menu",
           let lastExternalApplication {
            return lastExternalApplication
        }

        if let frontmost,
           isEligibleImmediateTarget(frontmost) {
            let target = targetApplication(from: frontmost)
            if isPreferredTrackedTarget(frontmost) {
                lastExternalApplication = target
            }
            return target
        }

        if let lastExternalApplication {
            return lastExternalApplication
        }

        throw AppError.noActiveApplication
    }

    private func resolveClipboardHistoryTargetApplication() throws -> ExternalApplicationTarget {
        if let target = preferredClipboardHistoryTargetApplication() {
            clipboardHistoryTargetApplication = target
            return target
        }

        if let clipboardHistoryTargetApplication {
            return clipboardHistoryTargetApplication
        }

        throw AppError.noActiveApplication
    }

    private func preferredClipboardHistoryTargetApplication() -> ExternalApplicationTarget? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isEligibleClipboardHistoryTarget(frontmost) {
            let target = targetApplication(from: frontmost)
            lastClipboardHistoryApplication = target
            if isPreferredTrackedTarget(frontmost) {
                lastExternalApplication = target
            }
            return target
        }

        return lastClipboardHistoryApplication ?? lastExternalApplication
    }

    // Observes the workspace for application activation notifications.
    private func observeWorkspace() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self,
                      self.isEligibleClipboardHistoryTarget(app) else { return }
                let target = self.targetApplication(from: app)
                self.lastClipboardHistoryApplication = target

                if self.isPreferredTrackedTarget(app) {
                    self.lastExternalApplication = target
                }

                await self.logger.log(
                    "workspace",
                    "Activated application",
                    metadata: [
                        "app": target.displayName,
                        "bundle_id": target.bundleIdentifier ?? "nil",
                        "tracked_for_text_source": "\(self.isPreferredTrackedTarget(app))",
                    ]
                )
            }
        }
    }

    // Determines if an application is an eligible immediate target.
    private func isEligibleImmediateTarget(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier != Bundle.main.bundleIdentifier &&
        app.bundleIdentifier != "com.apple.systemuiserver"
    }

    // Determines if an application can receive a Clipboard History paste.
    private func isEligibleClipboardHistoryTarget(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier != "com.apple.systemuiserver"
    }

    // Determines if an application is a preferred tracked target.
    private func isPreferredTrackedTarget(_ app: NSRunningApplication) -> Bool {
        guard isEligibleImmediateTarget(app) else { return false }

        let excludedBundleIDs: Set<String> = [
            "com.apple.systempreferences",
        ]

        if let bundleIdentifier = app.bundleIdentifier,
           excludedBundleIDs.contains(bundleIdentifier) {
            return false
        }

        return true
    }

    // Creates an ExternalApplicationTarget from an NSRunningApplication.
    private func targetApplication(from app: NSRunningApplication) -> ExternalApplicationTarget {
        ExternalApplicationTarget(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            localizedName: app.localizedName ?? app.bundleIdentifier ?? "Unknown App"
        )
    }

    // Returns a description of the target resolution.
    private func targetResolutionDescription(for trigger: String, resolved target: ExternalApplicationTarget) -> String {
        if trigger == "menu",
           lastExternalApplication == target {
            return "last_external_application"
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier == target.processIdentifier {
            return "frontmost_application"
        }

        return "fallback_application"
    }

    // Recomputes command issues, such as hotkey conflicts and duplicate command identifiers.
    private func recomputeCommandIssues() {
        var shortcutBuckets: [String: [UUID]] = [:]
        var commandIDBuckets: [String: [UUID]] = [:]

        for command in settings.commands {
            if let shortcut = command.shortcut {
                shortcutBuckets[shortcut.registrationKey, default: []].append(command.id)
            }

            let normalizedCommandID = command.commandID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedCommandID.isEmpty {
                commandIDBuckets[normalizedCommandID, default: []].append(command.id)
            }
        }

        if let shortcut = settings.clipboardHistoryShortcut {
            shortcutBuckets[shortcut.registrationKey, default: []].append(Self.clipboardHistoryShortcutID)
        }

        shortcutBuckets[settings.moveWindowShortcut.registrationKey, default: []].append(Self.moveWindowShortcutID)

        hotKeyConflicts = Set(shortcutBuckets.values.filter { $0.count > 1 }.flatMap { $0 })
        duplicateCommandIdentifiers = Set(commandIDBuckets.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    // Reconfigures the hotkeys.
    private func reconfigureHotKeys() {
        var bindings: [HotKeyBinding] = []
        var issues: [String] = hotKeyConflicts.compactMap { conflictID in
            guard let command = settings.commands.first(where: { $0.id == conflictID }),
                  let shortcut = command.shortcut else {
                return nil
            }
            return "Shortcut conflict: \(command.title) uses \(shortcut.displayString)"
        }

        for command in settings.commands {
            guard let shortcut = command.shortcut else { continue }
            guard shortcut.hasPrimaryModifier else {
                issues.append("Shortcut ignored for \(command.title): include Command, Option, or Control.")
                continue
            }
            guard !hotKeyConflicts.contains(command.id) else { continue }

            bindings.append(
                HotKeyBinding(
                    commandID: command.id,
                    title: command.title,
                    shortcut: shortcut
                )
            )
        }

        if let shortcut = settings.clipboardHistoryShortcut {
            if !shortcut.hasPrimaryModifier {
                issues.append("Shortcut ignored for Clipboard History: include Command, Option, or Control.")
            } else if hotKeyConflicts.contains(Self.clipboardHistoryShortcutID) {
                issues.append("Shortcut conflict: Clipboard History uses \(shortcut.displayString)")
            } else {
                bindings.append(
                    HotKeyBinding(
                        commandID: Self.clipboardHistoryShortcutID,
                        title: "Clipboard History",
                        shortcut: shortcut
                    )
                )
            }
        }



        let moveWindowShortcut = settings.moveWindowShortcut
        if !moveWindowShortcut.hasPrimaryModifier {
            issues.append("Shortcut ignored for Move Window to Next Monitor: include Command, Option, or Control.")
        } else if hotKeyConflicts.contains(Self.moveWindowShortcutID) {
            issues.append("Shortcut conflict: Move Window to Next Monitor uses \(moveWindowShortcut.displayString)")
        } else {
            bindings.append(
                HotKeyBinding(
                    commandID: Self.moveWindowShortcutID,
                    title: "Move Window to Next Monitor",
                    shortcut: moveWindowShortcut
                )
            )
        }

        issues.append(
            contentsOf: hotKeyService.configure(bindings: bindings) { [weak self] binding in
                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    if binding.commandID == Self.clipboardHistoryShortcutID {
                        self.requestOpenClipboardHistoryWindow()
                        return
                    }

                    if binding.commandID == Self.moveWindowShortcutID {
                        self.moveFocusedWindowToNextMonitor()
                        return
                    }

                    guard let command = self.settings.commands.first(where: { $0.id == binding.commandID }) else {
                        return
                    }
                    self.runCommand(command, trigger: "hotkey")
                }
            }
        )

        hotKeyIssues = issues
    }

    // Presents an error alert.
    private func presentErrorAlert(title: String, error: Error) {
        if let appError = error as? AppError, appError.suggestsOpeningAccessibilitySettings {
            promptForAccessibilityPermission()
            showAccessibilityAlert(title: title, message: appError.localizedDescription)
            return
        }

        showAlert(title: title, message: error.localizedDescription)
    }

    // Shows an alert that prompts the user to open the Accessibility settings.
    private func showAccessibilityAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    // Shows an alert.
    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func recordClipboardEntry(_ entry: ClipboardHistoryEntry) {
        if hasLoadedClipboardHistory {
            if selectedClipboardEntryID == nil {
                selectedClipboardEntryID = entry.id
            }
            if selectedClipboardEntryID == entry.id {
                selectedClipboardEntryDetail = entry
            }
        }

        Task {
            await clipboardHistoryService.upsert(entry)
            await clipboardHistoryService.prunePersistedEntries()
            if hasLoadedClipboardHistory {
                await reloadClipboardHistory()
            }
        }

        Task {
            await logger.log(
                "clipboard",
                "Captured clipboard history entry",
                metadata: [
                    "type": entry.contentType.rawValue,
                    "source_app": entry.sourceAppName,
                    "title": entry.title,
                ]
            )
        }
    }

    private func loadMoreClipboardHistoryEntries() async {
        let nextPage = await clipboardHistoryService.loadPersistedSummaries(
            searchText: clipboardHistorySearchText,
            filter: clipboardHistorySelectedFilter,
            offset: clipboardHistoryEntries.count,
            limit: clipboardHistoryPageSize
        )
        guard !nextPage.isEmpty else {
            hasMoreClipboardHistoryEntries = false
            return
        }
        clipboardHistoryEntries.append(contentsOf: nextPage)
        let totalCount = await clipboardHistoryService.countPersistedSummaries(
            searchText: clipboardHistorySearchText,
            filter: clipboardHistorySelectedFilter
        )
        hasMoreClipboardHistoryEntries = clipboardHistoryEntries.count < totalCount
    }

    private func loadSelectedClipboardEntryIfNeeded() async {
        guard let selectedClipboardEntryID else {
            selectedClipboardEntryDetail = nil
            isLoadingSelectedClipboardEntry = false
            return
        }
        if selectedClipboardEntryDetail?.id == selectedClipboardEntryID {
            return
        }

        isLoadingSelectedClipboardEntry = true
        let loadedEntry = await clipboardHistoryService.loadPersistedEntry(id: selectedClipboardEntryID)
        guard self.selectedClipboardEntryID == selectedClipboardEntryID else { return }
        selectedClipboardEntryDetail = loadedEntry
        isLoadingSelectedClipboardEntry = false
    }

    private func reloadClipboardHistory(resetSelection: Bool = false) async {
        hasLoadedClipboardHistory = true
        let summaries = await clipboardHistoryService.loadPersistedSummaries(
            searchText: clipboardHistorySearchText,
            filter: clipboardHistorySelectedFilter,
            offset: 0,
            limit: clipboardHistoryPageSize
        )
        let totalCount = await clipboardHistoryService.countPersistedSummaries(
            searchText: clipboardHistorySearchText,
            filter: clipboardHistorySelectedFilter
        )

        clipboardHistoryEntries = summaries
        hasMoreClipboardHistoryEntries = clipboardHistoryEntries.count < totalCount

        let visibleIDs = Set(clipboardHistoryEntries.map(\.id))
        if resetSelection || selectedClipboardEntryID == nil || !visibleIDs.contains(selectedClipboardEntryID!) {
            selectedClipboardEntryID = clipboardHistoryEntries.first?.id
            selectedClipboardEntryDetail = nil
        }

        await loadSelectedClipboardEntryIfNeeded()
    }

    private func promoteClipboardEntryToTop(_ entry: ClipboardHistoryEntry, reason: String) async {
        var promotedEntry = entry
        promotedEntry.capturedAt = Date()
        selectedClipboardEntryID = promotedEntry.id
        selectedClipboardEntryDetail = promotedEntry

        await clipboardHistoryService.upsert(promotedEntry)
        await reloadClipboardHistory()

        await logger.log(
            "clipboard",
            "Promoted clipboard history entry",
            metadata: [
                "reason": reason,
                "type": promotedEntry.contentType.rawValue,
                "source_app": promotedEntry.sourceAppName,
            ]
        )
    }


}
