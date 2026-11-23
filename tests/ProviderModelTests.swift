import AppKit
import Carbon
import Foundation

@main
@MainActor
struct ProviderModelTests {
    static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
        }
        var legacy = AppSettings.default
        legacy.apiBaseURL = "https://custom.example/v1"
        legacy.apiKey = "preserved-manual-key"
        legacy.providerModelCatalogs[AIProvider.openAICompatible.rawValue] = ["gpt-4o-mini", "custom-model"]
        legacy.defaultModel = "gpt-4o-mini"
        legacy.providerDefaultModels[AIProvider.openAICompatible.rawValue] = legacy.defaultModel
        legacy.commands[0].modelOverride = legacy.defaultModel
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let custom = try decoder.decode(AppSettings.self, from: encoder.encode(legacy))
        check(custom.apiBaseURL == legacy.apiBaseURL && custom.defaultModel == legacy.defaultModel, "Preserve custom endpoints")
        check(custom.apiKey == legacy.apiKey, "Preserve credentials")
        check(custom.modelCatalog(for: .openAICompatible).contains("custom-model"), "Preserve custom models")
        var object = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "reasoningByModel")
        object.removeValue(forKey: "reasoningEffortOverrides")
        object.removeValue(forKey: "defaultReasoningByModel")
        object.removeValue(forKey: "verifiedReasoningCapabilities")
        let old = try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        check(old.reasoningByModel.isEmpty && old.reasoningEffortOverrides.isEmpty, "Decode settings without reasoning definitions")
        legacy.reasoningByModel = ["OpenAI-Compatible:gpt-4o-mini": .low]
        let roundTrip = try decoder.decode(AppSettings.self, from: encoder.encode(legacy))
        check(roundTrip.reasoningByModel == legacy.reasoningByModel, "Persist per-model effort")
        check(ModelReasoning.modes(provider: .openAICompatible, model: "gpt-4o-mini", capability: nil) == [.modelDefault], "No hardcoded model efforts")
        check(ReasoningMode.noEffort.rawValue == "none" && ReasoningMode.noEffort.displayName == "None", "Keep explicit None distinct from Auto and Off")
        check(ModelReasoning.modes(provider: .openAICompatible, model: "accepts-none", capability: .init(supportedEfforts: ["high", "none", "none", "unknown"])) == [.modelDefault, .noEffort, .high], "Recognize catalog None and normalize model-specific choices")
        check(ModelReasoning.modes(provider: .openAICompatible, model: "no-none", capability: .init(supportedEfforts: ["low"])) == [.modelDefault, .low], "Do not show None for models without support")
        check(ModelReasoning.modes(provider: .openAICompatible, model: "unknown", capability: .init()) == [.modelDefault], "Do not invent efforts when metadata omits the list")
        var manual = AppSettings.default
        manual.setManualReasoningEfforts([.high, .low, .high, .disabled, .modelDefault], for: "custom-model", provider: .openAICompatible)
        check(manual.manualReasoningEfforts(for: "custom-model", provider: .openAICompatible) == [.low, .high], "Normalize manual efforts")
        manual.setManualReasoningEfforts([.max], for: "custom-model", provider: .deepSeek)
        let savedManual = try decoder.decode(AppSettings.self, from: encoder.encode(manual))
        check(savedManual.reasoningEffortOverrides == manual.reasoningEffortOverrides, "Persist definitions across settings reload")
        var noneSettings = manual
        noneSettings.setManualReasoningEfforts([.noEffort, .low], for: "none-model", provider: .openAICompatible)
        noneSettings.setDefaultReasoningMode(.noEffort, for: "none-model", provider: .openAICompatible)
        let restoredNone = try decoder.decode(AppSettings.self, from: encoder.encode(noneSettings))
        check(restoredNone.manualReasoningEfforts(for: "none-model", provider: .openAICompatible) == [.noEffort, .low], "Persist manual None per model")
        check(restoredNone.defaultReasoningMode(for: "none-model", provider: .openAICompatible, availableModes: [.modelDefault, .noEffort, .low]) == .noEffort, "Remember None as a model default")
        check(savedManual.manualReasoningEfforts(for: "custom-model", provider: .openRouter) == nil, "Keep provider definitions separate")
        check(savedManual.manualReasoningEfforts(for: "other-model", provider: .openAICompatible) == nil, "Keep model definitions separate")
        check(ModelReasoning.modes(provider: .openAICompatible, model: "custom-model", capability: .init(supportedEfforts: ["max"]), manualEfforts: savedManual.manualReasoningEfforts(for: "custom-model", provider: .openAICompatible)) == [.modelDefault, .low, .high], "Manual efforts override refreshed catalog metadata")
        manual.setManualReasoningEfforts([], for: "custom-model", provider: .openAICompatible)
        check(ModelReasoning.modes(provider: .openAICompatible, model: "custom-model", capability: .init(supportedEfforts: ["max"]), manualEfforts: manual.manualReasoningEfforts(for: "custom-model", provider: .openAICompatible)) == [.modelDefault], "Empty manual definition means Auto only")
        manual.setManualReasoningEfforts(nil, for: "custom-model", provider: .openAICompatible)
        check(manual.manualReasoningEfforts(for: "custom-model", provider: .openAICompatible) == nil, "Restore automatic discovery")
        check(ModelReasoning.modes(provider: .openAICompatible, model: "custom-model", capability: .init(supportedEfforts: ["max"]), manualEfforts: manual.manualReasoningEfforts(for: "custom-model", provider: .openAICompatible)) == [.modelDefault, .max], "Use catalog after removing override")
        check(manual.manualReasoningEfforts(for: "custom-model", provider: .deepSeek) == [.max], "Reset preserves other providers")
        check(ModelReasoning.modes(provider: .openAICompatible, model: "unknown", capability: nil) == [.modelDefault], "Unknown models use Auto")
        check(ModelReasoning.modes(provider: .openRouter, model: "test", capability: .init(mandatory: true, supportedEfforts: ["low", "max"])) == [.modelDefault, .low, .max], "Mandatory reasoning cannot be disabled")
        check(ModelReasoning.modes(provider: .deepSeek, model: "test", capability: .init(supportedEfforts: ["low", "max"])) == [.modelDefault, .low, .max], "Use provider catalog levels")
        var defaults = AppSettings.default
        defaults.setDefaultReasoningMode(.low, for: "model-a", provider: .openAICompatible)
        defaults.setDefaultReasoningMode(.high, for: "model-b", provider: .openAICompatible)
        defaults.setDefaultReasoningMode(.max, for: "model-a", provider: .deepSeek)
        let restoredDefaults = try decoder.decode(AppSettings.self, from: encoder.encode(defaults))
        check(restoredDefaults.defaultReasoningMode(for: "model-a", provider: .openAICompatible, availableModes: [.modelDefault, .low]) == .low, "Restore model A default")
        check(restoredDefaults.defaultReasoningMode(for: "model-b", provider: .openAICompatible, availableModes: [.modelDefault, .high]) == .high, "Switching models restores separate defaults")
        check(restoredDefaults.defaultReasoningMode(for: "model-a", provider: .deepSeek, availableModes: [.modelDefault, .max]) == .max, "Defaults are isolated by provider")
        check(restoredDefaults.defaultReasoningMode(for: "model-a", provider: .openAICompatible, availableModes: [.modelDefault]) == .modelDefault, "Removed effort falls back to Auto")
        check(restoredDefaults.defaultReasoningMode(for: "unknown", provider: .openAICompatible, availableModes: [.modelDefault, .low]) == .modelDefault, "Unconfigured model defaults to Auto")
        check(AICommand(commandID: "new", title: "New", promptTemplate: "{{text}}").useDefaultReasoning, "New commands inherit model reasoning")
        var oldCommand = try JSONSerialization.jsonObject(with: encoder.encode(defaults.commands[0])) as! [String: Any]
        oldCommand.removeValue(forKey: "useDefaultReasoning")
        let restoredCommand = try decoder.decode(AICommand.self, from: JSONSerialization.data(withJSONObject: oldCommand))
        check(!restoredCommand.useDefaultReasoning, "Preserve legacy explicit command choices")
        let testLoggerDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: testLoggerDir) }
        let client = AIClient(logger: AppLogger(directory: testLoggerDir, maxLogFileBytes: 1_500))
        let testURL = ProcessInfo.processInfo.environment["DAYDREAM_TEST_URL"] ?? "http://127.0.0.1:18765/v1"
        let bundledCapabilities = VerifiedReasoningCapability.bundled()
        check(bundledCapabilities.isEmpty, "Bundled capabilities snapshot starts empty")
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        let cached = VerifiedReasoningCapability(efforts: [.low, .high], checkedAt: checkedAt, endpoint: testURL, status: "verified")
        check(cached.isFresh(for: testURL + "/"), "Normalize cache endpoint trailing slash")
        var legacyCacheObject = try JSONSerialization.jsonObject(with: encoder.encode(cached)) as! [String: Any]
        legacyCacheObject.removeValue(forKey: "discoveryVersion")
        let legacyCache = try decoder.decode(VerifiedReasoningCapability.self, from: JSONSerialization.data(withJSONObject: legacyCacheObject))
        check(!legacyCache.isFresh(for: testURL), "Refresh legacy caches that never tested None")
        check(!cached.isFresh(for: "https://other.example/v1"), "Do not reuse checks across endpoints")
        check(!cached.isFresh(for: testURL, now: Date().addingTimeInterval(8 * 24 * 60 * 60)), "Expire checks after seven days")
        var fractionalCache = cached
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalCache.checkedAt = fractionalFormatter.string(from: Date().addingTimeInterval(-1))
        check(fractionalCache.isFresh(for: testURL), "Read snapshot timestamps with fractional seconds")
        var blockedCache = cached
        blockedCache.status = "region_blocked"
        check(!blockedCache.isFresh(for: testURL, now: Date().addingTimeInterval(16 * 60)), "Retry unavailable checks after fifteen minutes")
        defaults.verifiedReasoningCapabilities = [AIProvider.openAICompatible.rawValue: ["cached-model": cached]]
        let cachedRoundTrip = try decoder.decode(AppSettings.self, from: encoder.encode(defaults))
        check(cachedRoundTrip.verifiedReasoningCapabilities == defaults.verifiedReasoningCapabilities, "Persist verified capability cache")
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cacheURL = cacheDirectory.appendingPathComponent("verified-reasoning.json")
        VerifiedReasoningCapability.store(["cached-model": cached], at: cacheURL)
        check(VerifiedReasoningCapability.stored(at: cacheURL)["cached-model"] == cached, "Keep verification cache independent of synced settings")
        try? FileManager.default.removeItem(at: cacheDirectory)
        if CommandLine.arguments.contains("--requests") {
            let discovered = await ReasoningCapabilityDiscovery.discover(model: "discovery-supported", baseURL: testURL, apiKey: "")
            check(discovered.status == "verified" && discovered.efforts == [.low, .high], "Discover supported efforts with streaming positive and negative controls")
            let supportsNone = await ReasoningCapabilityDiscovery.discover(model: "discovery-none", baseURL: testURL, apiKey: "")
            check(supportsNone.efforts == [.noEffort, .low, .high], "Fetch probes None only as a supported explicit effort")
            check(ModelReasoning.modes(provider: .openAICompatible, model: "discovery-none", capability: .init(supportedEfforts: supportsNone.efforts.map(\.rawValue))) == [.modelDefault, .noEffort, .low, .high], "Settings and menu share the verified per-model choices")
            let ignored = await ReasoningCapabilityDiscovery.discover(model: "discovery-ignored", baseURL: testURL, apiKey: "")
            check(ignored.status == "parameter_not_validated" && ignored.efforts.isEmpty, "Do not mistake silently ignored fields for support")
            let blocked = await ReasoningCapabilityDiscovery.discover(model: "discovery-blocked", baseURL: testURL, apiKey: "")
            check(blocked.status == "region_blocked" && blocked.efforts.isEmpty, "Do not classify regional restrictions as unsupported reasoning")
            let media = await ReasoningCapabilityDiscovery.discover(model: "discovery-media", baseURL: testURL, apiKey: "")
            check(media.status == "streaming_unverified" && media.efforts.isEmpty, "Exclude media responses from text command verification")

            for provider in AIProvider.allCases {
                for mode in [ReasoningMode.modelDefault, .noEffort, .low, .high] {
                    _ = try await client.generateText(provider: provider,
                        openAICompatibleBaseURL: testURL, openAICompatibleAPIKey: "",
                        openRouterBaseURL: testURL, openRouterAPIKey: "",
                        deepSeekBaseURL: testURL, deepSeekAPIKey: "",
                        model: provider.rawValue, messages: [.init(role: "user", content: mode.rawValue)], reasoningMode: mode)
                    for try await _ in client.streamText(provider: provider,
                        openAICompatibleBaseURL: testURL, openAICompatibleAPIKey: "",
                        openRouterBaseURL: testURL, openRouterAPIKey: "",
                        deepSeekBaseURL: testURL, deepSeekAPIKey: "",
                        model: provider.rawValue, messages: [.init(role: "user", content: mode.rawValue)], reasoningMode: mode) {}
                }
            }
        }

        let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }
        let preferenceStore = SettingsStore(directory: settingsDirectory)
        var modelSettings = AppSettings.default
        modelSettings.providerModelCatalogs[AIProvider.openAICompatible.rawValue] = ["model-a", "model-b"]
        modelSettings.setDefaultModel("model-a", for: .openAICompatible)
        modelSettings.setDefaultReasoningMode(.low, for: "model-a", provider: .openAICompatible)
        preferenceStore.save(modelSettings)
        modelSettings.setDefaultModel("model-b", for: .openAICompatible)
        modelSettings.setDefaultReasoningMode(.high, for: "model-b", provider: .openAICompatible)
        preferenceStore.save(modelSettings)
        modelSettings.setDefaultModel("model-a", for: .openAICompatible)
        check(modelSettings.defaultReasoningMode(for: modelSettings.defaultModel, provider: .openAICompatible, availableModes: [.modelDefault, .low, .high]) == .low, "Switch A to B and back restores A's effort")
        preferenceStore.save(modelSettings)
        let restartedStore = SettingsStore(directory: settingsDirectory)
        var restartedSettings = restartedStore.load()
        check(restartedSettings.defaultReasoningByModel[AIProvider.openAICompatible.rawValue]?["model-a"] == .low, "Remember A after application restart")
        check(restartedSettings.defaultReasoningByModel[AIProvider.openAICompatible.rawValue]?["model-b"] == .high, "Remember B independently after application restart")
        let syncedSettingsURL = settingsDirectory.appendingPathComponent("cloud/settings.json")
        try FileManager.default.createDirectory(at: syncedSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var oldSyncedObject = try JSONSerialization.jsonObject(with: encoder.encode(modelSettings)) as! [String: Any]
        oldSyncedObject.removeValue(forKey: "defaultReasoningByModel")
        try JSONSerialization.data(withJSONObject: oldSyncedObject).write(to: syncedSettingsURL)
        restartedStore.useSyncedFileURL(syncedSettingsURL)
        restartedSettings = restartedStore.load()
        check(restartedSettings.defaultReasoningByModel[AIProvider.openAICompatible.rawValue]?["model-a"] == .low, "Older cloud settings cannot erase A's effort")
        check(restartedSettings.defaultReasoningByModel[AIProvider.openAICompatible.rawValue]?["model-b"] == .high, "Older cloud settings cannot erase B's effort")
        var staleSynced = restartedSettings
        staleSynced.setDefaultReasoningMode(.modelDefault, for: "model-a", provider: .openAICompatible)
        try encoder.encode(staleSynced).write(to: syncedSettingsURL)
        restartedSettings = restartedStore.load()
        check(restartedSettings.defaultReasoningByModel[AIProvider.openAICompatible.rawValue]?["model-a"] == .low, "A stale cloud Auto value cannot replace an explicit local choice")
        restartedSettings.setDefaultReasoningMode(.modelDefault, for: "model-a", provider: .openAICompatible)
        restartedStore.save(restartedSettings)
        let explicitlyReset = restartedStore.load()
        check(explicitlyReset.defaultReasoningByModel[AIProvider.openAICompatible.rawValue]?["model-a"] == .modelDefault, "An explicit local Auto selection replaces the remembered Low")
        check(explicitlyReset.defaultReasoningByModel[AIProvider.openAICompatible.rawValue]?["model-b"] == .high, "Resetting A does not change B")
        check(explicitlyReset.defaultReasoningMode(for: "model-b", provider: .openAICompatible, availableModes: [.modelDefault]) == .modelDefault, "Temporarily unavailable efforts use Auto")
        check(explicitlyReset.defaultReasoningMode(for: "model-b", provider: .openAICompatible, availableModes: [.modelDefault, .high]) == .high, "Restoring capabilities restores the remembered effort")
        var inheritedCommands = restartedStore.load()
        for index in inheritedCommands.commands.indices { inheritedCommands.commands[index].useDefaultReasoning = false }
        check(restartedStore.migrateCommandReasoningInheritance(in: &inheritedCommands), "Enable inheritance for existing commands on first migration")
        check(inheritedCommands.commands.allSatisfy(\.useDefaultReasoning), "Every existing command inherits the menu effort")
        restartedStore.save(inheritedCommands)
        var staleCommands = inheritedCommands
        for index in staleCommands.commands.indices { staleCommands.commands[index].useDefaultReasoning = false }
        try encoder.encode(staleCommands).write(to: syncedSettingsURL)
        var inheritedReload = restartedStore.load()
        check(inheritedReload.commands.allSatisfy(\.useDefaultReasoning), "Stale synced command flags cannot undo the inheritance migration")
        inheritedReload.commands[0].useDefaultReasoning = false
        restartedStore.save(inheritedReload)
        var explicitOverride = restartedStore.load()
        check(!restartedStore.migrateCommandReasoningInheritance(in: &explicitOverride), "Inheritance migration runs only once")
        check(!explicitOverride.commands[0].useDefaultReasoning && explicitOverride.commands.dropFirst().allSatisfy(\.useDefaultReasoning), "A later explicit command override stays independent")

        let pendingPopup = ResultPopupState(result: CommandExecutionResult(commandTitle: "Test", model: "test-model", output: "", originalSelection: "", captureSource: .accessibility, target: ExternalApplicationTarget(bundleIdentifier: nil, processIdentifier: 0, localizedName: "Test"), commandID: "test", selectionRestoreAnchor: nil), isStreaming: true)
        check(!pendingPopup.canApply, "A processing popup must not replace a selection with empty text")
        pendingPopup.result.output = "Result"
        check(pendingPopup.canApply, "Apply becomes available once actual output exists")


        let sync = ICloudSyncService()
        sync.refreshAvailability()
        sync.startObserving { _ in }
        sync.stopObserving()

        // Verify KeychainStore round-trip, plaintext JSON migration, and secret scrubbing.
        let keychainService = "Homer.daydream.tests.\(UUID().uuidString)"
        let testKeychain = KeychainStore(service: keychainService)
        defer { testKeychain.removeAll() }
        let secretDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: secretDir) }
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let rawLegacySettings: [String: Any] = [
            "apiKey": "test-api-secret",
            "openRouterAPIKey": "test-or-secret",
            "deepSeekAPIKey": "test-ds-secret",
            "tavilyAPIKey": "legacy-tavily-secret",
        ]
        let secretSettingsURL = secretDir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: rawLegacySettings).write(to: secretSettingsURL)
        let keychainSettingsStore = SettingsStore(directory: secretDir, credentialStore: testKeychain)
        var migratedSecrets = keychainSettingsStore.load()
        check(migratedSecrets.apiKey == "test-api-secret", "Migrate manual API key to Keychain")
        check(migratedSecrets.openRouterAPIKey == "test-or-secret", "Migrate OpenRouter API key to Keychain")
        check(migratedSecrets.deepSeekAPIKey == "test-ds-secret", "Migrate DeepSeek API key to Keychain")
        check(testKeychain.string(for: .openRouterAPIKey) == "test-or-secret", "Persist migrated secret in macOS Keychain")
        let scrubbedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: secretSettingsURL)) as! [String: Any]
        check(scrubbedJSON["apiKey"] == nil && scrubbedJSON["openRouterAPIKey"] == nil && scrubbedJSON["deepSeekAPIKey"] == nil && scrubbedJSON["tavilyAPIKey"] == nil, "Scrub all API keys from settings.json on disk")
        let reloadedFromKeychain = SettingsStore(directory: secretDir, credentialStore: testKeychain).load()
        check(reloadedFromKeychain.openRouterAPIKey == "test-or-secret" && reloadedFromKeychain.deepSeekAPIKey == "test-ds-secret", "Restore API keys from Keychain on restart")
        migratedSecrets.openRouterAPIKey = ""
        keychainSettingsStore.save(migratedSecrets)
        check(testKeychain.string(for: .openRouterAPIKey) == nil, "Clearing an API key deletes it from Keychain")

        // Verify corrupted settings.json is backed up and never overwritten with defaults.
        let corruptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: corruptDir) }
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptURL = corruptDir.appendingPathComponent("settings.json")
        let corruptPayload = Data("{ broken json".utf8)
        try corruptPayload.write(to: corruptURL)
        _ = SettingsStore(directory: corruptDir).load()
        check((try? Data(contentsOf: corruptURL)) == corruptPayload, "Never clobber corrupted settings.json on decode failure")
        let backupFiles = (try? FileManager.default.contentsOfDirectory(atPath: corruptDir.path)) ?? []
        check(backupFiles.contains(where: { $0.hasPrefix("settings.corrupted-") }), "Create timestamped backup for corrupted settings.json")

        // Verify Chinese + English bilingual tokenization in MemoryTokenizer.
        let memoryTokens = MemoryTokenizer.tokens(from: "请保持简洁自然的中文翻译风格，同时保留 Swift async/await 术语")
        let queryTokens = MemoryTokenizer.tokens(from: "帮我把这段 Swift 文档做中文翻译，语调保持简洁")
        check(!memoryTokens.intersection(queryTokens).isEmpty, "Match Chinese and English tokens in AI Memory")
        check(memoryTokens.contains("swift") && memoryTokens.contains("async"), "Keep Latin words >= 3 chars")

        // Verify persistent SQLite connection + FTS5 trigram substring search + short-query LIKE fallback.
        let clipDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: clipDir) }
        let clipStore = ClipboardHistoryStore(directory: clipDir)
        let now = Date()
        await clipStore.upsert(ClipboardHistoryEntry(
            capturedAt: now.addingTimeInterval(-10),
            sourceAppName: "Safari",
            contentType: .text,
            title: "双语词典测试",
            subtitle: "12 chars",
            plainText: "构建中英双语词典卡片到 Obsidian",
            imagePreview: nil,
            fileURLs: [],
            snapshot: .plainText("构建中英双语词典卡片到 Obsidian"),
            fingerprint: "fp-zh"
        ))
        await clipStore.upsert(ClipboardHistoryEntry(
            capturedAt: now,
            sourceAppName: "Xcode",
            contentType: .link,
            title: "https://api.example.com",
            subtitle: "URL",
            plainText: "https://api.example.com/api/openai/v1",
            imagePreview: nil,
            fileURLs: [],
            snapshot: .plainText("https://api.example.com/api/openai/v1"),
            fingerprint: "fp-en"
        ))
        let ftsZhHits = await clipStore.loadSummaries(searchText: "双语词典", filter: .all, offset: 0, limit: 10)
        check(ftsZhHits.count == 1 && ftsZhHits[0].fingerprint == "fp-zh", "FTS5 trigram matches >=3 char Chinese substring")
        let ftsEnHits = await clipStore.loadSummaries(searchText: "example", filter: .link, offset: 0, limit: 10)
        check(ftsEnHits.count == 1 && ftsEnHits[0].fingerprint == "fp-en", "FTS5 trigram matches >=3 char English substring with type filter")
        let shortHits = await clipStore.loadSummaries(searchText: "词典", filter: .all, offset: 0, limit: 10)
        check(shortHits.count == 1 && shortHits[0].fingerprint == "fp-zh", "2-char Chinese query falls back cleanly to LIKE")

        // Verify silent Obsidian local vault writer & path traversal sanitization.
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let fakeVault = fakeHome.appendingPathComponent("Documents/Obsidian Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeVault, withIntermediateDirectories: true)
        let writtenNote = try ObsidianNoteService.writeNoteSilentlyIfPossible(
            content: "# Serendipity\nMeaning",
            selectedText: "Serendipity\nignored line",
            vaultName: "Obsidian Vault",
            subfolder: "../Vocab/English",
            homeDirectory: fakeHome
        )
        check(writtenNote?.path == fakeVault.appendingPathComponent("Vocab/English/Serendipity.md").path, "Write Obsidian note silently to local vault without path traversal")

        // Verify single-pass template rendering (no recursive expansion) and expanded shortcut keys.
        let tplCommand = AICommand(
            commandID: "ctx",
            title: "Context Test",
            promptTemplate: "App={{app_name}} Date={{date}} Clip={{clipboard}} Text={{text}}"
        )
        let fixedDate = Date(timeIntervalSince1970: 1_795_132_800) // 2026-11-20 UTC
        let renderedPrompt = tplCommand.renderPrompt(
            with: "Literal {{clipboard}} stays literal",
            appName: "Xcode",
            clipboardText: "SECRET_CLIP",
            date: fixedDate
        )
        check(renderedPrompt.contains("App=Xcode") && renderedPrompt.contains("Clip=SECRET_CLIP") && renderedPrompt.contains("Text=Literal {{clipboard}} stays literal"), "Single-pass prompt rendering prevents recursive token expansion")
        check(KeyboardShortcut.keyLabel(for: UInt16(kVK_LeftArrow)) == "←" && KeyboardShortcut.keyLabel(for: UInt16(kVK_F5)) == "F5" && KeyboardShortcut.keyLabel(for: UInt16(kVK_Space)) == "Space", "Support arrow, function, and space shortcut keys")

        // Verify AppLogger rotation and combined tail read.
        for idx in 0..<40 {
            await AppLogger(directory: testLoggerDir, maxLogFileBytes: 1_200).log("test", "Log rotation line \(idx) padding-text-for-size")
        }
        let loggerInstance = AppLogger(directory: testLoggerDir, maxLogFileBytes: 1_200)
        for idx in 0..<30 {
            await loggerInstance.log("test", "Active logger line \(idx) padding-text-for-rotation-check")
        }
        check(FileManager.default.fileExists(atPath: loggerInstance.rotatedLogFileURL.path), "Rotate daydream.log to daydream.log.1 when exceeding max size")
        let combinedTail = await loggerInstance.readLogTail(maxLength: 2_000)
        check(combinedTail.contains("Active logger line 29"), "Read tail across rotated log files")

        // Verify backward-compatible AppSettings & AppInputSourceRule decoding for Input Source Switching.
        var inputSettingsSeed = AppSettings.default
        inputSettingsSeed.inputSourceSwitchingEnabled = false
        inputSettingsSeed.defaultEnglishInputSourceID = "com.apple.keylayout.US"
        inputSettingsSeed.appInputSourceRules = [
            AppInputSourceRule(
                bundleIdentifier: "com.tencent.xinWeChat",
                appName: "WeChat",
                inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
                isEnabled: false
            ),
        ]
        var legacyInputObject = try JSONSerialization.jsonObject(with: encoder.encode(inputSettingsSeed)) as! [String: Any]
        legacyInputObject.removeValue(forKey: "inputSourceSwitchingEnabled")
        legacyInputObject.removeValue(forKey: "defaultEnglishInputSourceID")
        legacyInputObject.removeValue(forKey: "appInputSourceRules")
        let decodedLegacyInput = try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacyInputObject))
        check(
            decodedLegacyInput.inputSourceSwitchingEnabled == true &&
            decodedLegacyInput.defaultEnglishInputSourceID == nil &&
            decodedLegacyInput.appInputSourceRules.isEmpty,
            "Absent input source switching keys decode to default enabled, nil English source, and empty rules"
        )
        let rawRuleWithoutEnabled: [String: Any] = [
            "bundleIdentifier": "com.tencent.xinWeChat",
            "appName": "WeChat",
            "inputSourceID": "com.apple.inputmethod.SCIM.ITABC",
        ]
        let decodedLegacyRule = try decoder.decode(AppInputSourceRule.self, from: JSONSerialization.data(withJSONObject: rawRuleWithoutEnabled))
        check(
            decodedLegacyRule.bundleIdentifier == "com.tencent.xinWeChat" &&
            decodedLegacyRule.appName == "WeChat" &&
            decodedLegacyRule.inputSourceID == "com.apple.inputmethod.SCIM.ITABC" &&
            decodedLegacyRule.isEnabled == true,
            "AppInputSourceRule defaults isEnabled to true when omitted from JSON"
        )

        // Verify AppSettings.normalizedAppInputSourceRules trimming, filtering, fallback appName, and deduplication.
        let normalizedRules = AppSettings.normalizedAppInputSourceRules([
            AppInputSourceRule(
                bundleIdentifier: "  com.tencent.xinWeChat \n",
                appName: "  WeChat  ",
                inputSourceID: "  com.apple.inputmethod.SCIM.ITABC\t",
                isEnabled: true
            ),
            AppInputSourceRule(
                bundleIdentifier: "   ",
                appName: "Blank Bundle",
                inputSourceID: "com.apple.keylayout.US"
            ),
            AppInputSourceRule(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                appName: "Slack",
                inputSourceID: " \n "
            ),
            AppInputSourceRule(
                bundleIdentifier: "  Homer.daydream  ",
                appName: "daydream",
                inputSourceID: "com.apple.keylayout.US"
            ),
            AppInputSourceRule(
                bundleIdentifier: " md.obsidian ",
                appName: "   ",
                inputSourceID: " im.rime.inputmethod.Squirrel ",
                isEnabled: false
            ),
            AppInputSourceRule(
                bundleIdentifier: "com.tencent.xinWeChat",
                appName: "WeChat Duplicate",
                inputSourceID: "com.apple.keylayout.ABC",
                isEnabled: false
            ),
        ])
        check(
            normalizedRules == [
                AppInputSourceRule(
                    bundleIdentifier: "com.tencent.xinWeChat",
                    appName: "WeChat",
                    inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
                    isEnabled: true
                ),
                AppInputSourceRule(
                    bundleIdentifier: "md.obsidian",
                    appName: "md.obsidian",
                    inputSourceID: "im.rime.inputmethod.Squirrel",
                    isEnabled: false
                ),
            ],
            "Normalize app input source rules by trimming, dropping invalid/self entries, falling back appName, and deduplicating in order"
        )

        // Verify SettingsStore local-vs-iCloud sync isolation and preservation of uninstalled third-party IME rules.
        let inputStoreDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: inputStoreDir) }
        let syncedInputURL = inputStoreDir.appendingPathComponent("cloud/settings.json")
        try FileManager.default.createDirectory(at: syncedInputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let syncedInputStore = SettingsStore(directory: inputStoreDir)
        syncedInputStore.useSyncedFileURL(syncedInputURL)
        var syncedInputSettings = AppSettings.default
        syncedInputSettings.inputSourceSwitchingEnabled = false
        syncedInputSettings.defaultEnglishInputSourceID = "com.apple.keylayout.US"
        syncedInputSettings.appInputSourceRules = [
            AppInputSourceRule(
                bundleIdentifier: "com.tencent.xinWeChat",
                appName: "WeChat",
                inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
                isEnabled: true
            ),
            AppInputSourceRule(
                bundleIdentifier: "md.obsidian",
                appName: "Obsidian",
                inputSourceID: "im.rime.inputmethod.Squirrel",
                isEnabled: true
            ),
        ]
        syncedInputStore.save(syncedInputSettings)
        let rawSyncedInputJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: syncedInputURL)) as! [String: Any]
        check(
            rawSyncedInputJSON["defaultEnglishInputSourceID"] as? String == "com.apple.keylayout.US" &&
            rawSyncedInputJSON["appInputSourceRules"] != nil,
            "Synced cloud settings.json persists defaultEnglishInputSourceID and appInputSourceRules"
        )
        check(
            rawSyncedInputJSON["inputSourceSwitchingEnabled"] == nil,
            "Synced cloud settings.json scrubs machine-local inputSourceSwitchingEnabled"
        )
        let reloadedInputStore = SettingsStore(directory: inputStoreDir)
        reloadedInputStore.useSyncedFileURL(syncedInputURL)
        let reloadedInputSettings = reloadedInputStore.load()
        check(
            reloadedInputSettings.inputSourceSwitchingEnabled == false,
            "Reloading SettingsStore preserves local inputSourceSwitchingEnabled == false from local-preferences.json"
        )
        reloadedInputStore.save(reloadedInputSettings)
        let roundTrippedSyncedSettings = reloadedInputStore.load()
        check(
            roundTrippedSyncedSettings.appInputSourceRules.contains(where: {
                $0.bundleIdentifier == "com.tencent.xinWeChat" &&
                $0.inputSourceID == "com.apple.inputmethod.SCIM.ITABC"
            }) &&
            roundTrippedSyncedSettings.appInputSourceRules.contains(where: {
                $0.bundleIdentifier == "md.obsidian" &&
                $0.inputSourceID == "im.rime.inputmethod.Squirrel"
            }),
            "Uninstalled third-party IME rules survive SettingsStore load() and save() intact"
        )

        // Verify InputSourceSwitchingService behavior with deterministic MockInputSourceBackend.
        let layoutType = CarbonInputSourceBackend.tisString(kTISTypeKeyboardLayout)
        let inputModeType = CarbonInputSourceBackend.tisString(kTISTypeKeyboardInputMode)
        let romajiSource = KeyboardInputSource(
            id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Roman",
            localizedName: "Romaji",
            sourceType: inputModeType,
            isASCIICapable: true,
            languages: ["en", "ja"]
        )
        let usSource = KeyboardInputSource(
            id: "com.apple.keylayout.US",
            localizedName: "U.S.",
            sourceType: layoutType,
            isASCIICapable: true,
            languages: ["en"]
        )
        let abcSource = KeyboardInputSource(
            id: "com.apple.keylayout.ABC",
            localizedName: "ABC",
            sourceType: layoutType,
            isASCIICapable: true,
            languages: ["en"]
        )
        let frenchSource = KeyboardInputSource(
            id: "com.apple.keylayout.French",
            localizedName: "French",
            sourceType: layoutType,
            isASCIICapable: true,
            languages: ["fr"]
        )
        let pinyinSource = KeyboardInputSource(
            id: "com.apple.inputmethod.SCIM.ITABC",
            localizedName: "Pinyin - Simplified",
            sourceType: inputModeType,
            isASCIICapable: false,
            languages: ["zh-Hans"]
        )

        let sampleWarningStatus = InputSourceSwitchingStatus.warning("Sample warning detail")
        check(
            sampleWarningStatus.displayText.hasPrefix("Warning: ") &&
            sampleWarningStatus.displayText.contains("Sample warning detail"),
            "Warning status displayText includes 'Warning: ' prefix and message detail"
        )

        check(
            InputSourceSwitchingService.resolveDefaultEnglishInputSource(
                preferredID: nil,
                availableSources: [romajiSource, usSource, pinyinSource],
                currentASCIILayoutID: romajiSource.id
            )?.id == "com.apple.keylayout.US",
            "English auto-detection prefers US keyboard layout over ASCII-capable Romaji input mode"
        )
        check(
            InputSourceSwitchingService.resolveDefaultEnglishInputSource(
                preferredID: nil,
                availableSources: [romajiSource, abcSource, pinyinSource],
                currentASCIILayoutID: nil
            )?.id == "com.apple.keylayout.ABC",
            "English auto-detection prefers ABC keyboard layout over ASCII-capable Romaji input mode"
        )
        check(
            InputSourceSwitchingService.resolveDefaultEnglishInputSource(
                preferredID: nil,
                availableSources: [frenchSource, usSource],
                currentASCIILayoutID: "com.apple.keylayout.French"
            )?.id == "com.apple.keylayout.US",
            "Non-English MRU ASCII layout (French) does not override English keyboard layout (U.S.)"
        )
        check(
            InputSourceSwitchingService.resolveDefaultEnglishInputSource(
                preferredID: nil,
                availableSources: [abcSource, usSource],
                currentASCIILayoutID: "com.apple.keylayout.US"
            )?.id == "com.apple.keylayout.US",
            "English MRU ASCII layout (U.S.) is selected when both ABC and U.S. layouts are available"
        )

        let inputLoggerDir = inputStoreDir.appendingPathComponent("Logs", isDirectory: true)
        let mockBackend = MockInputSourceBackend(
            sources: [romajiSource, usSource, pinyinSource],
            currentSourceID: usSource.id,
            asciiLayoutSourceID: romajiSource.id
        )
        let switchingService = InputSourceSwitchingService(
            logger: AppLogger(directory: inputLoggerDir, maxLogFileBytes: 4_096),
            backend: mockBackend,
            settleDelay: .milliseconds(5),
            verificationDelay: .milliseconds(10)
        )
        defer { switchingService.stop() }
        switchingService.onStatusChange = { [weak mockBackend] status in
            mockBackend?.recordedStatuses.append(status)
        }

        let weChatRule = AppInputSourceRule(
            bundleIdentifier: "com.tencent.xinWeChat",
            appName: "WeChat",
            inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
            isEnabled: true
        )
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: nil,
            rules: [weChatRule]
        )
        check(
            switchingService.currentStatus == .active(defaultEnglishName: "U.S.", activeRuleCount: 1),
            "Service auto-detects U.S. layout as default English over ASCII input modes"
        )

        let weChatApp = RunningAppSnapshot(bundleIdentifier: "com.tencent.xinWeChat", localizedName: "WeChat")
        let terminalApp = RunningAppSnapshot(bundleIdentifier: "com.apple.Terminal", localizedName: "Terminal")

        // Configured app switches to Pinyin; unconfigured app switches back to US English.
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "Activating configured WeChat switches to Pinyin"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = terminalApp
        await switchingService.performSwitchForTesting(terminalApp)
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Activating unconfigured Terminal switches back to default US English"
        )

        // Idempotency when target source is already active (unconfigured + configured).
        mockBackend.selectedIDs.removeAll()
        await switchingService.performSwitchForTesting(terminalApp)
        check(
            mockBackend.selectedIDs.isEmpty,
            "Idempotency: activating Terminal when US English is already active makes 0 selectInputSource calls"
        )

        mockBackend.currentSourceID = "com.apple.inputmethod.SCIM.ITABC"
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        check(
            mockBackend.selectedIDs.isEmpty,
            "Idempotency: activating WeChat when Pinyin is already active makes 0 selectInputSource calls"
        )

        // Pausing a rule (isEnabled: false) makes that app fall back to default English.
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: "com.apple.keylayout.US",
            rules: [
                AppInputSourceRule(
                    bundleIdentifier: "com.tencent.xinWeChat",
                    appName: "WeChat",
                    inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
                    isEnabled: false
                ),
            ]
        )
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Pausing an app rule makes that app switch to default English"
        )

        // CJKV TSM revert retry: first selection gets reverted before verificationDelay, retry succeeds.
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: "com.apple.keylayout.US",
            rules: [weChatRule]
        )
        mockBackend.currentSourceID = "com.apple.keylayout.US"
        mockBackend.selectedIDs.removeAll()
        mockBackend.revertNextSelectionToSourceID = "com.apple.keylayout.US"
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        check(
            mockBackend.selectedIDs == [
                "com.apple.inputmethod.SCIM.ITABC",
                "com.apple.inputmethod.SCIM.ITABC",
            ] &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC",
            "Verification pass retries once and succeeds when CJKV selection is reverted before verificationDelay"
        )

        // Unconfigured .accessory apps and ignored bundle IDs make 0 switches, whereas an explicit rule for an .accessory app switches to its configured source.
        let raycastApp = RunningAppSnapshot(bundleIdentifier: "com.raycast.macos", localizedName: "Raycast", activationPolicy: .accessory)
        mockBackend.currentSourceID = "com.apple.inputmethod.SCIM.ITABC"
        mockBackend.selectedIDs.removeAll()
        for ignoredApp in [
            raycastApp,
            RunningAppSnapshot(bundleIdentifier: "Homer.daydream", localizedName: "daydream", activationPolicy: .regular),
            RunningAppSnapshot(bundleIdentifier: "com.apple.systemuiserver", localizedName: "SystemUIServer", activationPolicy: .regular),
        ] {
            mockBackend.frontmostApp = ignoredApp
            await switchingService.performSwitchForTesting(ignoredApp)
        }
        check(
            mockBackend.selectedIDs.isEmpty &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC",
            "Unconfigured accessory apps and ignored bundle IDs are ignored with 0 input source switches"
        )

        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: "com.apple.keylayout.US",
            rules: [
                weChatRule,
                AppInputSourceRule(
                    bundleIdentifier: "com.raycast.macos",
                    appName: "Raycast",
                    inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
                    isEnabled: true
                ),
            ]
        )
        mockBackend.currentSourceID = "com.apple.keylayout.US"
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = raycastApp
        await switchingService.performSwitchForTesting(raycastApp)
        check(
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"] &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC",
            "Explicitly configured accessory (LSUIElement) app switches to its configured input source"
        )

        // Rapid app-activation cancellation: activating appA immediately followed by appB cancels appA before selection so only appB's source is selected.
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: "com.apple.keylayout.US",
            rules: [weChatRule]
        )
        mockBackend.currentSourceID = romajiSource.id
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = weChatApp
        switchingService.handleApplicationActivated(weChatApp)
        mockBackend.frontmostApp = terminalApp
        switchingService.handleApplicationActivated(terminalApp)
        try await Task.sleep(for: .milliseconds(45))
        check(
            !mockBackend.selectedIDs.contains("com.apple.inputmethod.SCIM.ITABC") &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"] &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US",
            "Rapid app-activation cancels pending previous switch so only the latest app's target input source is selected"
        )

        // Unavailable synced defaultEnglishInputSourceID falls back to auto-detected US English without mutating settings.
        var unavailableEnglishSettings = reloadedInputStore.load()
        unavailableEnglishSettings.defaultEnglishInputSourceID = "com.apple.keylayout.Dvorak"
        reloadedInputStore.save(unavailableEnglishSettings)
        let syncedDvorakSettings = reloadedInputStore.load()
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: syncedDvorakSettings.defaultEnglishInputSourceID,
            rules: [weChatRule]
        )
        mockBackend.currentSourceID = "com.apple.inputmethod.SCIM.ITABC"
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = terminalApp
        await switchingService.performSwitchForTesting(terminalApp)
        check(
            mockBackend.selectedIDs == ["com.apple.keylayout.US"] &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            switchingService.currentStatus == .active(defaultEnglishName: "U.S.", activeRuleCount: 1) &&
            syncedDvorakSettings.defaultEnglishInputSourceID == "com.apple.keylayout.Dvorak" &&
            reloadedInputStore.load().defaultEnglishInputSourceID == "com.apple.keylayout.Dvorak",
            "Unavailable synced defaultEnglishInputSourceID (Dvorak) falls back to auto-detected U.S. without mutating settings"
        )

        // Missing per-app IME emits .warning and makes 0 selectInputSource calls (preserving current source).
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: "com.apple.keylayout.US",
            rules: [
                weChatRule,
                AppInputSourceRule(
                    bundleIdentifier: "md.obsidian",
                    appName: "Obsidian",
                    inputSourceID: "im.rime.inputmethod.Squirrel",
                    isEnabled: true
                ),
            ]
        )
        mockBackend.currentSourceID = "com.apple.inputmethod.SCIM.ITABC"
        mockBackend.selectedIDs.removeAll()
        mockBackend.recordedStatuses.removeAll()
        let obsidianApp = RunningAppSnapshot(bundleIdentifier: "md.obsidian", localizedName: "Obsidian")
        mockBackend.frontmostApp = obsidianApp
        await switchingService.performSwitchForTesting(obsidianApp)
        let emittedWarning: Bool
        if case .warning = switchingService.currentStatus {
            emittedWarning = true
        } else {
            emittedWarning = false
        }
        check(
            emittedWarning &&
            switchingService.currentStatus.displayText.hasPrefix("Warning: ") &&
            switchingService.currentStatus.displayText.contains("Obsidian") &&
            mockBackend.recordedStatuses.contains(where: {
                if case .warning = $0 { return $0.displayText.hasPrefix("Warning: ") }
                return false
            }) &&
            mockBackend.selectedIDs.isEmpty &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC",
            "Missing per-app IME emits warning status and makes 0 selectInputSource calls without overwriting current source"
        )

        // Persistent selectInputSource failure (paramErr / unchanged currentSourceID on initial + retry) emits .warning after 2 attempts.
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: "com.apple.keylayout.US",
            rules: [weChatRule]
        )
        mockBackend.currentSourceID = "com.apple.keylayout.US"
        mockBackend.selectedIDs.removeAll()
        mockBackend.recordedStatuses.removeAll()
        mockBackend.refuseSelection = true
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        mockBackend.refuseSelection = false
        let emittedPersistentFailureWarning: Bool
        if case .warning = switchingService.currentStatus {
            emittedPersistentFailureWarning = true
        } else {
            emittedPersistentFailureWarning = false
        }
        check(
            mockBackend.selectedIDs.count == 2 &&
            mockBackend.selectedIDs == [
                "com.apple.inputmethod.SCIM.ITABC",
                "com.apple.inputmethod.SCIM.ITABC",
            ] &&
            emittedPersistentFailureWarning &&
            switchingService.currentStatus.displayText.hasPrefix("Warning: ") &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US",
            "Persistent selectInputSource failure retries once (2 calls total) and surfaces a Warning status"
        )

        // Default Spotlight -> English & underlying app restore when Spotlight is dismissed with Esc.
        mockBackend.accessibilityTrusted = true
        mockBackend.spotlightActive = false
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: nil,
            rules: [weChatRule]
        )
        mockBackend.currentSourceID = "com.apple.keylayout.US"
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "Activating WeChat before opening Spotlight switches to Pinyin"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightActive = true
        await switchingService.performSpotlightCheckForTesting()
        check(
            mockBackend.frontmostApp == weChatApp &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Opening Spotlight over WeChat switches to default US English while WeChat remains frontmost"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightActive = false
        await switchingService.performSpotlightCheckForTesting()
        check(
            mockBackend.frontmostApp == weChatApp &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "Dismissing Spotlight with Esc restores underlying WeChat Pinyin input source"
        )

        // Custom Spotlight rule ("com.apple.Spotlight") switches to configured source and restores underlying app on dismiss.
        let spotlightRule = AppInputSourceRule(
            bundleIdentifier: "com.apple.Spotlight",
            appName: "Spotlight",
            inputSourceID: "com.apple.inputmethod.SCIM.ITABC"
        )
        mockBackend.spotlightActive = false
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: nil,
            rules: [spotlightRule]
        )
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = terminalApp
        await switchingService.performSwitchForTesting(terminalApp)
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Activating unconfigured Terminal switches to default US English"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightActive = true
        await switchingService.performSpotlightCheckForTesting()
        check(
            mockBackend.frontmostApp == terminalApp &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "Opening Spotlight with custom com.apple.Spotlight rule switches to Pinyin while Terminal remains frontmost"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightActive = false
        await switchingService.performSpotlightCheckForTesting()
        check(
            mockBackend.frontmostApp == terminalApp &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Dismissing Spotlight restores underlying Terminal default US English input source"
        )

        // Paused Spotlight rule (isEnabled: false) falls back to default English.
        let pausedSpotlightRule = AppInputSourceRule(
            bundleIdentifier: "com.apple.Spotlight",
            appName: "Spotlight",
            inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
            isEnabled: false
        )
        mockBackend.spotlightActive = false
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: nil,
            rules: [weChatRule, pausedSpotlightRule]
        )
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "WeChat switches to Pinyin before opening Spotlight with paused Spotlight rule"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightActive = true
        await switchingService.performSpotlightCheckForTesting()
        check(
            mockBackend.frontmostApp == weChatApp &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Paused Spotlight rule falls back to default US English when Spotlight opens over WeChat"
        )
        mockBackend.spotlightActive = false
        await switchingService.performSpotlightCheckForTesting()

        // Spotlight appName canonicalization ("Siri" -> "Spotlight").
        let canonicalizedSpotlightRules = AppSettings.normalizedAppInputSourceRules([
            AppInputSourceRule(
                bundleIdentifier: "com.apple.Spotlight",
                appName: "Siri",
                inputSourceID: "com.apple.inputmethod.SCIM.ITABC"
            ),
        ])
        check(
            canonicalizedSpotlightRules == [
                AppInputSourceRule(
                    bundleIdentifier: "com.apple.Spotlight",
                    appName: "Spotlight",
                    inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
                    isEnabled: true
                ),
            ],
            "Canonicalize Siri appName on com.apple.Spotlight to Spotlight"
        )

        // Launching/activating a third app (configured Notes or unconfigured Terminal) from Spotlight switches cleanly to that app's target input source.
        let notesRule = AppInputSourceRule(
            bundleIdentifier: "com.apple.Notes",
            appName: "Notes",
            inputSourceID: "com.apple.inputmethod.SCIM.ITABC",
            isEnabled: true
        )
        let notesApp = RunningAppSnapshot(bundleIdentifier: "com.apple.Notes", localizedName: "Notes")
        mockBackend.accessibilityTrusted = true
        mockBackend.spotlightState = .inactive
        mockBackend.frontmostApp = nil
        switchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: nil,
            rules: [weChatRule, notesRule]
        )
        mockBackend.currentSourceID = "com.apple.keylayout.US"
        mockBackend.selectedIDs.removeAll()
        mockBackend.frontmostApp = weChatApp
        await switchingService.performSwitchForTesting(weChatApp)
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "Start in WeChat with Pinyin before opening Spotlight to launch a third app"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightState = .activeFocusedElement
        await switchingService.performSpotlightCheckForTesting()
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Opening Spotlight over WeChat switches to US English"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightState = .inactive
        mockBackend.frontmostApp = notesApp
        await switchingService.performSwitchForTesting(notesApp)
        check(
            mockBackend.frontmostApp == notesApp &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            mockBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "Activating configured Notes from Spotlight while Spotlight closes switches cleanly to Notes' target input source"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightState = .activeFocusedElement
        await switchingService.performSpotlightCheckForTesting()
        check(
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs == ["com.apple.keylayout.US"],
            "Re-opening Spotlight over Notes switches back to US English"
        )

        mockBackend.selectedIDs.removeAll()
        mockBackend.spotlightState = .inactive
        mockBackend.frontmostApp = terminalApp
        await switchingService.performSwitchForTesting(terminalApp)
        check(
            mockBackend.frontmostApp == terminalApp &&
            mockBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US" &&
            mockBackend.selectedIDs.isEmpty,
            "Activating unconfigured Terminal from Spotlight keeps US English cleanly with 0 redundant switches"
        )

        // Signal B (.activeFallbackWindow) mid-fade-out recovery when launching a third app from Spotlight.
        let fallbackBackend = MockInputSourceBackend(
            sources: [romajiSource, usSource, pinyinSource],
            currentSourceID: usSource.id,
            asciiLayoutSourceID: usSource.id
        )
        fallbackBackend.accessibilityTrusted = false
        fallbackBackend.spotlightState = .activeFocusedElement
        check(
            fallbackBackend.spotlightActivityState(wasSpotlightActive: true) == .inactive,
            "MockInputSourceBackend reports .inactive when accessibilityTrusted is false"
        )
        fallbackBackend.accessibilityTrusted = true
        fallbackBackend.spotlightState = .inactive
        fallbackBackend.recordedSpotlightStates.removeAll()

        let fallbackSwitchingService = InputSourceSwitchingService(
            logger: AppLogger(directory: inputLoggerDir, maxLogFileBytes: 4_096),
            backend: fallbackBackend,
            settleDelay: .milliseconds(5),
            verificationDelay: .milliseconds(10),
            fallbackSettleDelay: .milliseconds(15)
        )
        defer { fallbackSwitchingService.stop() }
        fallbackSwitchingService.configure(
            enabled: true,
            defaultEnglishInputSourceID: nil,
            rules: [weChatRule]
        )

        fallbackBackend.frontmostApp = terminalApp
        await fallbackSwitchingService.performSwitchForTesting(terminalApp)
        check(
            fallbackBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US",
            "Start in Terminal with US English before opening Spotlight"
        )

        fallbackBackend.spotlightState = .activeFocusedElement
        await fallbackSwitchingService.performSpotlightCheckForTesting()
        check(
            fallbackBackend.currentKeyboardInputSourceID() == "com.apple.keylayout.US",
            "Open Spotlight (.activeFocusedElement) over Terminal in US English"
        )

        fallbackBackend.selectedIDs.removeAll()
        fallbackBackend.recordedSpotlightStates.removeAll()
        fallbackBackend.frontmostApp = weChatApp
        fallbackBackend.queuedSpotlightStates = [.activeFallbackWindow, .inactive]
        await fallbackSwitchingService.performSwitchForTesting(weChatApp)
        check(
            fallbackBackend.recordedSpotlightStates.first == .activeFallbackWindow &&
            fallbackBackend.recordedSpotlightStates.last == .inactive &&
            fallbackBackend.currentKeyboardInputSourceID() == "com.apple.inputmethod.SCIM.ITABC" &&
            fallbackBackend.selectedIDs == ["com.apple.inputmethod.SCIM.ITABC"],
            "Launching WeChat from Spotlight while panel fades through .activeFallbackWindow -> .inactive recovers after fallbackSettleDelay and switches to Pinyin"
        )

        print("Provider model, discovery, migration, Keychain, SQLite FTS5, Obsidian, Input Source Switching, and single-file iCloud query checks passed")
    }
}

@MainActor
private final class MockInputSourceBackend: InputSourceBackend {
    var sources: [KeyboardInputSource]
    var currentSourceID: String?
    var asciiLayoutSourceID: String?
    var frontmostApp: RunningAppSnapshot?
    var accessibilityTrusted = true
    var spotlightState: SpotlightActivityState = .inactive
    var queuedSpotlightStates: [SpotlightActivityState] = []
    var onSelectOrNextSpotlightState: ((Bool) -> SpotlightActivityState)?
    var recordedSpotlightStates: [SpotlightActivityState] = []
    var selectedIDs: [String] = []
    var revertNextSelectionToSourceID: String?
    var refuseSelection = false
    var recordedStatuses: [InputSourceSwitchingStatus] = []

    var spotlightActive: Bool {
        get { spotlightState != .inactive }
        set { spotlightState = newValue ? .activeFocusedElement : .inactive }
    }

    init(
        sources: [KeyboardInputSource],
        currentSourceID: String?,
        asciiLayoutSourceID: String? = nil,
        frontmostApp: RunningAppSnapshot? = nil
    ) {
        self.sources = sources
        self.currentSourceID = currentSourceID
        self.asciiLayoutSourceID = asciiLayoutSourceID
        self.frontmostApp = frontmostApp
    }

    func selectableKeyboardInputSources() -> [KeyboardInputSource] {
        sources
    }

    func currentKeyboardInputSourceID() -> String? {
        currentSourceID
    }

    func currentASCIICapableLayoutInputSourceID() -> String? {
        asciiLayoutSourceID
    }

    @discardableResult
    func selectInputSource(id: String) -> OSStatus {
        selectedIDs.append(id)
        if refuseSelection {
            return OSStatus(paramErr)
        }
        currentSourceID = id
        if let revertedID = revertNextSelectionToSourceID {
            revertNextSelectionToSourceID = nil
            currentSourceID = revertedID
        }
        return noErr
    }

    func frontmostApplication() -> RunningAppSnapshot? {
        frontmostApp
    }

    func isAccessibilityTrusted() -> Bool {
        accessibilityTrusted
    }

    func spotlightActivityState(wasSpotlightActive: Bool) -> SpotlightActivityState {
        guard accessibilityTrusted else {
            recordedSpotlightStates.append(.inactive)
            return .inactive
        }
        let resolvedState: SpotlightActivityState
        if let onSelectOrNextSpotlightState {
            resolvedState = onSelectOrNextSpotlightState(wasSpotlightActive)
        } else if !queuedSpotlightStates.isEmpty {
            resolvedState = queuedSpotlightStates.removeFirst()
            spotlightState = resolvedState
        } else {
            resolvedState = spotlightState
        }
        recordedSpotlightStates.append(resolvedState)
        return resolvedState
    }

    func isSpotlightActive(wasSpotlightActive: Bool) -> Bool {
        spotlightActivityState(wasSpotlightActive: wasSpotlightActive) != .inactive
    }
}


