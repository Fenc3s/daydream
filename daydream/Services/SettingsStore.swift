import Foundation

final class SettingsStore {
    private struct LocalPreferences: Codable {
        var syncWithICloud: Bool
        var iCloudPasswordsDiaAutomationEnabled: Bool?
        var inputSourceSwitchingEnabled: Bool?
        var commandReasoningInheritanceMigrated: Bool?
    }

    private static let secretJSONKeys: Set<String> = [
        AppSettings.CodingKeys.apiKey.rawValue,
        AppSettings.CodingKeys.openRouterAPIKey.rawValue,
        AppSettings.CodingKeys.deepSeekAPIKey.rawValue,
        "tavilyAPIKey",
    ]

    private let fileManager: FileManager
    private let baseDirectory: URL
    private let localFileURL: URL
    private let localProviderFileURL: URL
    private let localPreferencesFileURL: URL
    private let localModelReasoningFileURL: URL
    private let localCommandReasoningFileURL: URL
    private let credentialStore: any CredentialStoring
    private var syncedFileURL: URL?
    private var cachedCredentials: [CredentialAccount: String] = [:]

    var fileURL: URL {
        syncedFileURL ?? localFileURL
    }

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        credentialStore: (any CredentialStoring)? = nil
    ) {
        self.fileManager = fileManager
        let resolvedDirectory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream", isDirectory: true)
        baseDirectory = resolvedDirectory
        try? fileManager.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
        localFileURL = resolvedDirectory.appendingPathComponent("settings.json", isDirectory: false)
        localProviderFileURL = resolvedDirectory.appendingPathComponent("provider.json", isDirectory: false)
        localPreferencesFileURL = resolvedDirectory.appendingPathComponent("local-preferences.json", isDirectory: false)
        localModelReasoningFileURL = resolvedDirectory.appendingPathComponent("model-reasoning-preferences.json", isDirectory: false)
        localCommandReasoningFileURL = resolvedDirectory.appendingPathComponent("command-reasoning-preferences.json", isDirectory: false)
        if let credentialStore {
            self.credentialStore = credentialStore
        } else if directory != nil {
            self.credentialStore = DirectoryCredentialStore(directory: resolvedDirectory)
        } else {
            self.credentialStore = KeychainStore()
        }
    }

    func useSyncedFileURL(_ url: URL?) {
        syncedFileURL = url
    }

    func prefersICloudSync() -> Bool {
        loadLocalPreferences()?.syncWithICloud ?? true
    }

    func ensureCredentialsLoaded(for provider: AIProvider, in settings: inout AppSettings) {
        let account = CredentialAccount(provider: provider)
        let hadCachedValue = cachedCredentials[account] != nil
        let stored = loadCredential(for: account)
        guard !hadCachedValue else { return }
        switch provider {
        case .openAICompatible:
            if settings.apiKey.isEmpty { settings.apiKey = stored }
        case .openRouter:
            if settings.openRouterAPIKey.isEmpty { settings.openRouterAPIKey = stored }
        case .deepSeek:
            if settings.deepSeekAPIKey.isEmpty { settings.deepSeekAPIKey = stored }
        }
    }

    func load(activeProviderOnly: Bool = false) -> AppSettings {
        let targetURL = fileURL
        let isCoordinated = syncedFileURL != nil

        guard fileManager.fileExists(atPath: targetURL.path) else {
            var settings = AppSettings.default
            applyLocalPreferences(to: &settings)
            if syncedFileURL != nil, let localProvider = loadLocalProvider() {
                settings.provider = localProvider
                settings.defaultModel = settings.defaultModel(for: localProvider)
            }
            restoreCredentials(into: &settings, activeProviderOnly: activeProviderOnly)
            save(settings)
            return settings
        }

        guard let data = readData(from: targetURL, coordinated: isCoordinated) else {
            // Transient read failure (e.g. pending iCloud download): never clobber the file on disk.
            var fallback = AppSettings.default
            applyLocalPreferences(to: &fallback)
            if syncedFileURL != nil, let localProvider = loadLocalProvider() {
                fallback.provider = localProvider
                fallback.defaultModel = fallback.defaultModel(for: localProvider)
            }
            restoreCredentials(into: &fallback, activeProviderOnly: activeProviderOnly)
            return fallback
        }

        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            applyLocalPreferences(to: &settings)
            if syncedFileURL != nil, let localProvider = loadLocalProvider() {
                settings.provider = localProvider
                settings.defaultModel = settings.defaultModel(for: localProvider)
            }
            let needsSecretScrub = migrateOrRestoreCredentials(
                in: &settings,
                rawData: data,
                activeProviderOnly: activeProviderOnly
            )
            if syncedFileURL != nil || needsSecretScrub {
                save(settings, existingFileData: data)
            }
            return settings
        } catch {
            backupCorruptedSettingsData(data)
            var fallback = AppSettings.default
            applyLocalPreferences(to: &fallback)
            if syncedFileURL != nil, let localProvider = loadLocalProvider() {
                fallback.provider = localProvider
                fallback.defaultModel = fallback.defaultModel(for: localProvider)
            }
            restoreCredentials(into: &fallback, activeProviderOnly: activeProviderOnly)
            return fallback
        }
    }

    func save(_ settings: AppSettings, existingFileData: Data? = nil) {
        var settings = settings
        // Preserve remembered models when an older synced file omits their keys.
        for (provider, choices) in loadModelReasoningPreferences() {
            for (model, mode) in choices where settings.defaultReasoningByModel[provider]?[model] == nil {
                settings.defaultReasoningByModel[provider, default: [:]][model] = mode
            }
        }
        persistCredentials(from: settings)
        saveModelReasoningPreferences(settings.defaultReasoningByModel)
        saveCommandReasoningPreferences(settings.commands)
        saveLocalProvider(settings.provider)
        saveLocalPreferences(
            syncWithICloud: settings.syncWithICloud,
            iCloudPasswordsDiaAutomationEnabled: settings.iCloudPasswordsDiaAutomationEnabled,
            inputSourceSwitchingEnabled: settings.inputSourceSwitchingEnabled
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        let outputData = sanitizedSettingsData(from: data, isSyncedTarget: syncedFileURL != nil)
        writeIfChanged(outputData, to: fileURL, coordinated: syncedFileURL != nil, existingData: existingFileData)
    }

    func migrateCommandReasoningInheritance(in settings: inout AppSettings) -> Bool {
        guard loadLocalPreferences()?.commandReasoningInheritanceMigrated != true else { return false }
        for index in settings.commands.indices { settings.commands[index].useDefaultReasoning = true }
        saveLocalPreferences(
            syncWithICloud: settings.syncWithICloud,
            iCloudPasswordsDiaAutomationEnabled: settings.iCloudPasswordsDiaAutomationEnabled,
            inputSourceSwitchingEnabled: settings.inputSourceSwitchingEnabled,
            commandReasoningInheritanceMigrated: true
        )
        return true
    }

    private func loadLocalProvider() -> AIProvider? {
        if let data = try? Data(contentsOf: localProviderFileURL),
           let provider = try? JSONDecoder().decode(AIProvider.self, from: data) {
            return provider
        }

        guard let data = try? Data(contentsOf: localFileURL),
              let localSettings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return nil
        }

        saveLocalProvider(localSettings.provider)
        return localSettings.provider
    }

    private func saveLocalProvider(_ provider: AIProvider) {
        guard let data = try? JSONEncoder().encode(provider) else { return }
        writeIfChanged(data, to: localProviderFileURL)
    }

    private func loadCommandReasoningPreferences() -> [String: Bool] {
        guard let data = try? Data(contentsOf: localCommandReasoningFileURL),
              let choices = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return choices
    }

    private func saveCommandReasoningPreferences(_ commands: [AICommand]) {
        var choices = loadCommandReasoningPreferences()
        for command in commands { choices[command.id.uuidString] = command.useDefaultReasoning }
        guard let data = try? JSONEncoder().encode(choices) else { return }
        writeIfChanged(data, to: localCommandReasoningFileURL)
    }

    private func loadModelReasoningPreferences() -> [String: [String: ReasoningMode]] {
        guard let data = try? Data(contentsOf: localModelReasoningFileURL),
              let choices = try? JSONDecoder().decode([String: [String: ReasoningMode]].self, from: data) else { return [:] }
        return choices
    }

    private func saveModelReasoningPreferences(_ choices: [String: [String: ReasoningMode]]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(choices) else { return }
        writeIfChanged(data, to: localModelReasoningFileURL)
    }

    private func loadLocalPreferences() -> LocalPreferences? {
        guard let data = try? Data(contentsOf: localPreferencesFileURL) else { return nil }
        return try? JSONDecoder().decode(LocalPreferences.self, from: data)
    }

    private func applyLocalPreferences(to settings: inout AppSettings) {
        let localPreferences = loadLocalPreferences()
        // This Mac's explicit selections win over synced defaults for the same model.
        for (provider, choices) in loadModelReasoningPreferences() {
            settings.defaultReasoningByModel[provider, default: [:]].merge(choices) { _, local in local }
        }
        saveModelReasoningPreferences(settings.defaultReasoningByModel)
        let commandChoices = loadCommandReasoningPreferences()
        for index in settings.commands.indices {
            if let choice = commandChoices[settings.commands[index].id.uuidString] {
                settings.commands[index].useDefaultReasoning = choice
            }
        }
        saveCommandReasoningPreferences(settings.commands)
        settings.syncWithICloud = localPreferences?.syncWithICloud ?? true
        settings.iCloudPasswordsDiaAutomationEnabled = localPreferences?.iCloudPasswordsDiaAutomationEnabled ?? true
        settings.inputSourceSwitchingEnabled = localPreferences?.inputSourceSwitchingEnabled ?? settings.inputSourceSwitchingEnabled
        saveLocalPreferences(
            syncWithICloud: settings.syncWithICloud,
            iCloudPasswordsDiaAutomationEnabled: settings.iCloudPasswordsDiaAutomationEnabled,
            inputSourceSwitchingEnabled: settings.inputSourceSwitchingEnabled
        )
    }

    private func saveLocalPreferences(
        syncWithICloud: Bool,
        iCloudPasswordsDiaAutomationEnabled: Bool,
        inputSourceSwitchingEnabled: Bool,
        commandReasoningInheritanceMigrated: Bool? = nil
    ) {
        let preferences = LocalPreferences(
            syncWithICloud: syncWithICloud,
            iCloudPasswordsDiaAutomationEnabled: iCloudPasswordsDiaAutomationEnabled,
            inputSourceSwitchingEnabled: inputSourceSwitchingEnabled,
            commandReasoningInheritanceMigrated: commandReasoningInheritanceMigrated
                ?? loadLocalPreferences()?.commandReasoningInheritanceMigrated
        )
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        writeIfChanged(data, to: localPreferencesFileURL)
    }

    private func loadCredential(for account: CredentialAccount) -> String {
        if let cached = cachedCredentials[account] {
            return cached
        }
        let stored = credentialStore.string(for: account) ?? ""
        cachedCredentials[account] = stored
        return stored
    }

    private func persistCredential(_ value: String, for account: CredentialAccount) {
        if let cached = cachedCredentials[account] {
            guard cached != value else { return }
            credentialStore.setString(value, for: account)
            cachedCredentials[account] = value
        } else if !value.isEmpty {
            credentialStore.setString(value, for: account)
            cachedCredentials[account] = value
        }
    }

    private func persistCredentials(from settings: AppSettings) {
        persistCredential(settings.apiKey, for: .openAICompatibleAPIKey)
        persistCredential(settings.openRouterAPIKey, for: .openRouterAPIKey)
        persistCredential(settings.deepSeekAPIKey, for: .deepSeekAPIKey)
    }

    private func shouldLoadCredential(_ account: CredentialAccount, for provider: AIProvider, activeProviderOnly: Bool) -> Bool {
        if !activeProviderOnly || cachedCredentials[account] != nil {
            return true
        }
        return account == CredentialAccount(provider: provider)
    }

    private func restoreCredentials(into settings: inout AppSettings, activeProviderOnly: Bool = false) {
        let provider = settings.provider
        if shouldLoadCredential(.openAICompatibleAPIKey, for: provider, activeProviderOnly: activeProviderOnly) {
            settings.apiKey = loadCredential(for: .openAICompatibleAPIKey)
        }
        if shouldLoadCredential(.openRouterAPIKey, for: provider, activeProviderOnly: activeProviderOnly) {
            settings.openRouterAPIKey = loadCredential(for: .openRouterAPIKey)
        }
        if shouldLoadCredential(.deepSeekAPIKey, for: provider, activeProviderOnly: activeProviderOnly) {
            settings.deepSeekAPIKey = loadCredential(for: .deepSeekAPIKey)
        }
    }

    private func migrateOrRestoreCredentials(
        in settings: inout AppSettings,
        rawData: Data,
        activeProviderOnly: Bool = false
    ) -> Bool {
        let rawObject = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any]
        let hasSecretKeysOnDisk = rawObject.map { object in
            !Self.secretJSONKeys.isDisjoint(with: object.keys)
        } ?? false
        let provider = settings.provider
        let loadActiveOnly = activeProviderOnly && !hasSecretKeysOnDisk

        func resolve(_ jsonValue: String, account: CredentialAccount) -> String {
            guard shouldLoadCredential(account, for: provider, activeProviderOnly: loadActiveOnly) || !jsonValue.isEmpty else {
                return ""
            }
            let stored = loadCredential(for: account)
            if !jsonValue.isEmpty {
                if stored.isEmpty {
                    credentialStore.setString(jsonValue, for: account)
                    cachedCredentials[account] = jsonValue
                    return jsonValue
                }
                return stored
            }
            return stored
        }

        settings.apiKey = resolve(settings.apiKey, account: .openAICompatibleAPIKey)
        settings.openRouterAPIKey = resolve(settings.openRouterAPIKey, account: .openRouterAPIKey)
        settings.deepSeekAPIKey = resolve(settings.deepSeekAPIKey, account: .deepSeekAPIKey)
        return hasSecretKeysOnDisk
    }

    private func sanitizedSettingsData(from data: Data, isSyncedTarget: Bool) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        for secretKey in Self.secretJSONKeys {
            object.removeValue(forKey: secretKey)
        }

        if isSyncedTarget {
            object.removeValue(forKey: AppSettings.CodingKeys.provider.rawValue)
            object.removeValue(forKey: AppSettings.CodingKeys.defaultModel.rawValue)
            object.removeValue(forKey: AppSettings.CodingKeys.syncWithICloud.rawValue)
            object.removeValue(forKey: AppSettings.CodingKeys.iCloudPasswordsDiaAutomationEnabled.rawValue)
            object.removeValue(forKey: AppSettings.CodingKeys.inputSourceSwitchingEnabled.rawValue)
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? data
    }

    private func backupCorruptedSettingsData(_ data: Data) {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = baseDirectory.appendingPathComponent("settings.corrupted-\(timestamp).json", isDirectory: false)
        try? data.write(to: backupURL, options: [.atomic])
    }

    private func readData(from url: URL, coordinated: Bool) -> Data? {
        guard coordinated else {
            return try? Data(contentsOf: url)
        }

        var coordinatorError: NSError?
        var loadedData: Data?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            loadedData = try? Data(contentsOf: coordinatedURL)
        }
        if coordinatorError != nil {
            return try? Data(contentsOf: url)
        }
        return loadedData
    }

    private func writeIfChanged(_ data: Data, to url: URL, coordinated: Bool = false, existingData: Data? = nil) {
        if let currentData = existingData ?? readData(from: url, coordinated: coordinated), currentData == data {
            return
        }

        if coordinated {
            var coordinatorError: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
                try? fileManager.createDirectory(at: coordinatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: coordinatedURL, options: [.atomic])
            }
            if coordinatorError != nil {
                try? data.write(to: url, options: [.atomic])
            }
            return
        }

        try? data.write(to: url, options: [.atomic])
    }
}
