import Foundation

final class SettingsStore {
    private struct LegacyLocalPreferences: Codable {
        var iCloudPasswordsDiaAutomationEnabled: Bool?
        var inputSourceSwitchingEnabled: Bool?
        var commandReasoningInheritanceMigrated: Bool?
    }

    private enum DefaultsKey {
        static let appSettings = "daydream.appSettings"
        static let commandReasoningInheritanceMigrated = "daydream.commandReasoningInheritanceMigrated"
    }

    private static let secretJSONKeys: Set<String> = [
        "apiKey",
        AppSettings.CodingKeys.openRouterAPIKey.rawValue,
        AppSettings.CodingKeys.deepSeekAPIKey.rawValue,
        "tavilyAPIKey",
    ]

    private let fileManager: FileManager
    private let legacyDirectory: URL
    private let legacySettingsFileURL: URL
    private let legacyProviderFileURL: URL
    private let legacyPreferencesFileURL: URL
    private let legacyModelReasoningFileURL: URL
    private let legacyCommandReasoningFileURL: URL
    private let userDefaults: UserDefaults
    private let suiteName: String?
    private let credentialStore: any CredentialStoring
    private var cachedCredentials: [CredentialAccount: String] = [:]

    var fileURL: URL {
        let domain = suiteName ?? Bundle.main.bundleIdentifier ?? "Homer.daydream"
        return fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("\(domain).plist", isDirectory: false)
    }

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        userDefaults: UserDefaults? = nil,
        credentialStore: (any CredentialStoring)? = nil
    ) {
        self.fileManager = fileManager
        let resolvedDirectory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("daydream", isDirectory: true)
        legacyDirectory = resolvedDirectory
        legacySettingsFileURL = resolvedDirectory.appendingPathComponent("settings.json", isDirectory: false)
        legacyProviderFileURL = resolvedDirectory.appendingPathComponent("provider.json", isDirectory: false)
        legacyPreferencesFileURL = resolvedDirectory.appendingPathComponent("local-preferences.json", isDirectory: false)
        legacyModelReasoningFileURL = resolvedDirectory.appendingPathComponent("model-reasoning-preferences.json", isDirectory: false)
        legacyCommandReasoningFileURL = resolvedDirectory.appendingPathComponent("command-reasoning-preferences.json", isDirectory: false)

        if let userDefaults {
            self.userDefaults = userDefaults
            suiteName = nil
        } else if let directory {
            let isolatedSuite = "Homer.daydream.tests.\(directory.lastPathComponent)"
            suiteName = isolatedSuite
            self.userDefaults = UserDefaults(suiteName: isolatedSuite) ?? .standard
        } else {
            suiteName = nil
            self.userDefaults = .standard
        }

        if let credentialStore {
            self.credentialStore = credentialStore
        } else if directory != nil {
            try? fileManager.createDirectory(at: resolvedDirectory, withIntermediateDirectories: true)
            self.credentialStore = DirectoryCredentialStore(directory: resolvedDirectory)
        } else {
            self.credentialStore = KeychainStore()
        }
    }

    var credentials: any CredentialStoring {
        credentialStore
    }

    func ensureCredentialsLoaded(for provider: AIProvider, in settings: inout AppSettings) {
        guard provider != .chatGPT else { return }
        let account = CredentialAccount(provider: provider)
        let hadCachedValue = cachedCredentials[account] != nil
        let stored = loadCredential(for: account)
        guard !hadCachedValue else { return }
        switch provider {
        case .openRouter:
            if settings.openRouterAPIKey.isEmpty { settings.openRouterAPIKey = stored }
        case .deepSeek:
            if settings.deepSeekAPIKey.isEmpty { settings.deepSeekAPIKey = stored }
        case .chatGPT:
            break
        }
    }

    func load(activeProviderOnly: Bool = false) -> AppSettings {
        if let storedData = userDefaults.data(forKey: DefaultsKey.appSettings) {
            do {
                var settings = try JSONDecoder().decode(AppSettings.self, from: storedData)
                let needsSecretScrub = migrateOrRestoreCredentials(
                    in: &settings,
                    rawData: storedData,
                    activeProviderOnly: activeProviderOnly
                )
                if needsSecretScrub {
                    save(settings)
                }
                return settings
            } catch {
                var fallback = AppSettings.default
                restoreCredentials(into: &fallback, activeProviderOnly: activeProviderOnly)
                return fallback
            }
        }

        if let migrated = migrateLegacyFilesIfPresent(activeProviderOnly: activeProviderOnly) {
            return migrated
        }

        var settings = AppSettings.default
        restoreCredentials(into: &settings, activeProviderOnly: activeProviderOnly)
        save(settings)
        return settings
    }

    func save(_ settings: AppSettings) {
        persistCredentials(from: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        let outputData = sanitizedSettingsData(from: data)
        if userDefaults.data(forKey: DefaultsKey.appSettings) != outputData {
            userDefaults.set(outputData, forKey: DefaultsKey.appSettings)
        }
    }

    func migrateCommandReasoningInheritance(in settings: inout AppSettings) -> Bool {
        guard !userDefaults.bool(forKey: DefaultsKey.commandReasoningInheritanceMigrated) else { return false }
        for index in settings.commands.indices {
            settings.commands[index].useDefaultReasoning = true
        }
        userDefaults.set(true, forKey: DefaultsKey.commandReasoningInheritanceMigrated)
        return true
    }

    func storedSettingsDataForTesting() -> Data? {
        userDefaults.data(forKey: DefaultsKey.appSettings)
    }

    private func migrateLegacyFilesIfPresent(activeProviderOnly: Bool) -> AppSettings? {
        guard fileManager.fileExists(atPath: legacySettingsFileURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: legacySettingsFileURL) else {
            var fallback = AppSettings.default
            restoreCredentials(into: &fallback, activeProviderOnly: activeProviderOnly)
            return fallback
        }

        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            applyLegacySidecarPreferences(to: &settings)
            _ = migrateOrRestoreCredentials(
                in: &settings,
                rawData: data,
                activeProviderOnly: activeProviderOnly
            )
            save(settings)
            removeLegacySettingsFiles()
            return settings
        } catch {
            backupCorruptedSettingsData(data)
            var fallback = AppSettings.default
            restoreCredentials(into: &fallback, activeProviderOnly: activeProviderOnly)
            return fallback
        }
    }

    private func applyLegacySidecarPreferences(to settings: inout AppSettings) {
        if let data = try? Data(contentsOf: legacyModelReasoningFileURL),
           let choices = try? JSONDecoder().decode([String: [String: ReasoningMode]].self, from: data) {
            for (provider, modelChoices) in choices {
                settings.defaultReasoningByModel[provider, default: [:]].merge(modelChoices) { _, local in local }
            }
        }

        if let data = try? Data(contentsOf: legacyCommandReasoningFileURL),
           let commandChoices = try? JSONDecoder().decode([String: Bool].self, from: data) {
            for index in settings.commands.indices {
                if let choice = commandChoices[settings.commands[index].id.uuidString] {
                    settings.commands[index].useDefaultReasoning = choice
                }
            }
        }

        if let data = try? Data(contentsOf: legacyPreferencesFileURL),
           let localPreferences = try? JSONDecoder().decode(LegacyLocalPreferences.self, from: data) {
            if let enabled = localPreferences.iCloudPasswordsDiaAutomationEnabled {
                settings.iCloudPasswordsDiaAutomationEnabled = enabled
            }
            if let enabled = localPreferences.inputSourceSwitchingEnabled {
                settings.inputSourceSwitchingEnabled = enabled
            }
            if localPreferences.commandReasoningInheritanceMigrated == true {
                userDefaults.set(true, forKey: DefaultsKey.commandReasoningInheritanceMigrated)
            }
        }
    }

    private func removeLegacySettingsFiles() {
        for url in [
            legacySettingsFileURL,
            legacyProviderFileURL,
            legacyPreferencesFileURL,
            legacyModelReasoningFileURL,
            legacyCommandReasoningFileURL,
        ] {
            try? fileManager.removeItem(at: url)
        }
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

        settings.openRouterAPIKey = resolve(settings.openRouterAPIKey, account: .openRouterAPIKey)
        settings.deepSeekAPIKey = resolve(settings.deepSeekAPIKey, account: .deepSeekAPIKey)
        return hasSecretKeysOnDisk
    }

    private func sanitizedSettingsData(from data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        for secretKey in Self.secretJSONKeys {
            object.removeValue(forKey: secretKey)
        }

        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
    }

    private func backupCorruptedSettingsData(_ data: Data) {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = legacyDirectory.appendingPathComponent("settings.corrupted-\(timestamp).json", isDirectory: false)
        try? data.write(to: backupURL, options: [.atomic])
    }
}
