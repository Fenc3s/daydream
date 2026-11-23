import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation

@main
@MainActor
struct ProviderModelTests {
    static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
        }
        var legacy = AppSettings.default
        legacy.openRouterBaseURL = "https://custom.example/v1"
        legacy.openRouterAPIKey = "preserved-manual-key"
        legacy.providerModelCatalogs[AIProvider.openRouter.rawValue] = [AppSettings.openRouterDefaultModel, "custom-model"]
        legacy.defaultModel = AppSettings.openRouterDefaultModel
        legacy.providerDefaultModels[AIProvider.openRouter.rawValue] = legacy.defaultModel
        legacy.commands[0].modelOverride = legacy.defaultModel
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let custom = try decoder.decode(AppSettings.self, from: encoder.encode(legacy))
        check(custom.openRouterBaseURL == legacy.openRouterBaseURL && custom.defaultModel == legacy.defaultModel, "Preserve custom endpoints")
        check(custom.openRouterAPIKey == legacy.openRouterAPIKey, "Preserve credentials")
        check(custom.modelCatalog(for: .openRouter).contains("custom-model"), "Preserve custom models")
        var object = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        object["provider"] = "OpenAI-Compatible"
        object["defaultModel"] = "gpt-4o-mini"
        object.removeValue(forKey: "reasoningByModel")
        object.removeValue(forKey: "reasoningEffortOverrides")
        object.removeValue(forKey: "defaultReasoningByModel")
        object.removeValue(forKey: "verifiedReasoningCapabilities")
        let old = try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        check(old.provider == .openRouter && old.defaultModel == AppSettings.openRouterDefaultModel, "Migrate removed OpenAI-Compatible provider to OpenRouter")
        check(old.reasoningByModel.isEmpty && old.reasoningEffortOverrides.isEmpty, "Decode settings without reasoning definitions")
        legacy.reasoningByModel = ["OpenRouter:google/gemini-3.5-flash-lite": .low]
        let roundTrip = try decoder.decode(AppSettings.self, from: encoder.encode(legacy))
        check(roundTrip.reasoningByModel == legacy.reasoningByModel, "Persist per-model effort")
        check(ModelReasoning.modes(provider: .deepSeek, model: "deepseek-v4-flash", capability: nil) == [.modelDefault], "No hardcoded model efforts")
        check(ReasoningMode.noEffort.rawValue == "none" && ReasoningMode.noEffort.displayName == "None", "Keep explicit None distinct from Auto and Off")
        check(ModelReasoning.modes(provider: .deepSeek, model: "accepts-none", capability: .init(supportedEfforts: ["high", "none", "none", "unknown"])) == [.modelDefault, .noEffort, .high], "Recognize catalog None and normalize model-specific choices")
        check(ModelReasoning.modes(provider: .deepSeek, model: "no-none", capability: .init(supportedEfforts: ["low"])) == [.modelDefault, .low], "Do not show None for models without support")
        check(ModelReasoning.modes(provider: .deepSeek, model: "unknown", capability: .init()) == [.modelDefault], "Do not invent efforts when metadata omits the list")
        var manual = AppSettings.default
        manual.setManualReasoningEfforts([.high, .low, .high, .disabled, .modelDefault], for: "custom-model", provider: .openRouter)
        check(manual.manualReasoningEfforts(for: "custom-model", provider: .openRouter) == [.low, .high], "Normalize manual efforts")
        manual.setManualReasoningEfforts([.max], for: "custom-model", provider: .deepSeek)
        let savedManual = try decoder.decode(AppSettings.self, from: encoder.encode(manual))
        check(savedManual.reasoningEffortOverrides == manual.reasoningEffortOverrides, "Persist definitions across settings reload")
        var noneSettings = manual
        noneSettings.setManualReasoningEfforts([.noEffort, .low], for: "none-model", provider: .openRouter)
        noneSettings.setDefaultReasoningMode(.noEffort, for: "none-model", provider: .openRouter)
        let restoredNone = try decoder.decode(AppSettings.self, from: encoder.encode(noneSettings))
        check(restoredNone.manualReasoningEfforts(for: "none-model", provider: .openRouter) == [.noEffort, .low], "Persist manual None per model")
        check(restoredNone.defaultReasoningMode(for: "none-model", provider: .openRouter, availableModes: [.modelDefault, .noEffort, .low]) == .noEffort, "Remember None as a model default")
        check(savedManual.manualReasoningEfforts(for: "other-model", provider: .openRouter) == nil, "Keep model definitions separate")
        check(ModelReasoning.modes(provider: .deepSeek, model: "custom-model", capability: .init(supportedEfforts: ["max"]), manualEfforts: savedManual.manualReasoningEfforts(for: "custom-model", provider: .openRouter)) == [.modelDefault, .low, .high], "Manual efforts override refreshed catalog metadata")
        manual.setManualReasoningEfforts([], for: "custom-model", provider: .openRouter)
        check(ModelReasoning.modes(provider: .deepSeek, model: "custom-model", capability: .init(supportedEfforts: ["max"]), manualEfforts: manual.manualReasoningEfforts(for: "custom-model", provider: .openRouter)) == [.modelDefault], "Empty manual definition means Auto only")
        manual.setManualReasoningEfforts(nil, for: "custom-model", provider: .openRouter)
        check(manual.manualReasoningEfforts(for: "custom-model", provider: .openRouter) == nil, "Restore automatic discovery")
        check(ModelReasoning.modes(provider: .deepSeek, model: "custom-model", capability: .init(supportedEfforts: ["max"]), manualEfforts: manual.manualReasoningEfforts(for: "custom-model", provider: .openRouter)) == [.modelDefault, .max], "Use catalog after removing override")
        check(manual.manualReasoningEfforts(for: "custom-model", provider: .deepSeek) == [.max], "Reset preserves other providers")
        check(ModelReasoning.modes(provider: .deepSeek, model: "unknown", capability: nil) == [.modelDefault], "Unknown models use Auto")
        check(ModelReasoning.modes(provider: .openRouter, model: "test", capability: .init(mandatory: true, supportedEfforts: ["low", "max"])) == [.modelDefault, .low, .max], "Mandatory reasoning cannot be disabled")
        check(ModelReasoning.modes(provider: .deepSeek, model: "test", capability: .init(supportedEfforts: ["low", "max"])) == [.modelDefault, .low, .max], "Use provider catalog levels")
        var defaults = AppSettings.default
        defaults.setDefaultReasoningMode(.low, for: "model-a", provider: .openRouter)
        defaults.setDefaultReasoningMode(.high, for: "model-b", provider: .openRouter)
        defaults.setDefaultReasoningMode(.max, for: "model-a", provider: .deepSeek)
        let restoredDefaults = try decoder.decode(AppSettings.self, from: encoder.encode(defaults))
        check(restoredDefaults.defaultReasoningMode(for: "model-a", provider: .openRouter, availableModes: [.modelDefault, .low]) == .low, "Restore model A default")
        check(restoredDefaults.defaultReasoningMode(for: "model-b", provider: .openRouter, availableModes: [.modelDefault, .high]) == .high, "Switching models restores separate defaults")
        check(restoredDefaults.defaultReasoningMode(for: "model-a", provider: .deepSeek, availableModes: [.modelDefault, .max]) == .max, "Defaults are isolated by provider")
        check(restoredDefaults.defaultReasoningMode(for: "model-a", provider: .openRouter, availableModes: [.modelDefault]) == .modelDefault, "Removed effort falls back to Auto")
        check(restoredDefaults.defaultReasoningMode(for: "unknown", provider: .openRouter, availableModes: [.modelDefault, .low]) == .modelDefault, "Unconfigured model defaults to Auto")
        check(AICommand(commandID: "new", title: "New", promptTemplate: "{{text}}").useDefaultReasoning, "New commands inherit model reasoning")
        var oldCommand = try JSONSerialization.jsonObject(with: encoder.encode(defaults.commands[0])) as! [String: Any]
        oldCommand.removeValue(forKey: "useDefaultReasoning")
        let restoredCommand = try decoder.decode(AICommand.self, from: JSONSerialization.data(withJSONObject: oldCommand))
        check(!restoredCommand.useDefaultReasoning, "Preserve legacy explicit command choices")
        let testLoggerDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: testLoggerDir) }
        let client = AIClient(logger: AppLogger(directory: testLoggerDir, maxLogFileBytes: 1_500))
        let testURL = ProcessInfo.processInfo.environment["DAYDREAM_TEST_URL"] ?? "http://127.0.0.1:18765/v1"
        if CommandLine.arguments.contains("--requests") {
            for provider in AIProvider.allCases {
                for mode in [ReasoningMode.modelDefault, .noEffort, .low, .high] {
                    _ = try await client.generateText(provider: provider,
                        openRouterBaseURL: testURL, openRouterAPIKey: "",
                        deepSeekBaseURL: testURL, deepSeekAPIKey: "",
                        model: provider.rawValue, messages: [.init(role: "user", content: mode.rawValue)], reasoningMode: mode)
                    for try await _ in client.streamText(provider: provider,
                        openRouterBaseURL: testURL, openRouterAPIKey: "",
                        deepSeekBaseURL: testURL, deepSeekAPIKey: "",
                        model: provider.rawValue, messages: [.init(role: "user", content: mode.rawValue)], reasoningMode: mode) {}
                }
            }
        }

        let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "Homer.daydream.tests.\(settingsDirectory.lastPathComponent)")
            try? FileManager.default.removeItem(at: settingsDirectory)
        }
        let preferenceStore = SettingsStore(directory: settingsDirectory)
        var modelSettings = AppSettings.default
        modelSettings.providerModelCatalogs[AIProvider.openRouter.rawValue] = ["model-a", "model-b"]
        modelSettings.setDefaultModel("model-a", for: .openRouter)
        modelSettings.setDefaultReasoningMode(.low, for: "model-a", provider: .openRouter)
        preferenceStore.save(modelSettings)
        modelSettings.setDefaultModel("model-b", for: .openRouter)
        modelSettings.setDefaultReasoningMode(.high, for: "model-b", provider: .openRouter)
        preferenceStore.save(modelSettings)
        modelSettings.setDefaultModel("model-a", for: .openRouter)
        check(modelSettings.defaultReasoningMode(for: modelSettings.defaultModel, provider: .openRouter, availableModes: [.modelDefault, .low, .high]) == .low, "Switch A to B and back restores A's effort")
        preferenceStore.save(modelSettings)
        let restartedStore = SettingsStore(directory: settingsDirectory)
        var restartedSettings = restartedStore.load()
        check(restartedSettings.defaultReasoningByModel[AIProvider.openRouter.rawValue]?["model-a"] == .low, "Remember A after application restart")
        check(restartedSettings.defaultReasoningByModel[AIProvider.openRouter.rawValue]?["model-b"] == .high, "Remember B independently after application restart")
        restartedSettings.setDefaultReasoningMode(.modelDefault, for: "model-a", provider: .openRouter)
        restartedStore.save(restartedSettings)
        let explicitlyReset = restartedStore.load()
        check(explicitlyReset.defaultReasoningByModel[AIProvider.openRouter.rawValue]?["model-a"] == .modelDefault, "An explicit local Auto selection replaces the remembered Low")
        check(explicitlyReset.defaultReasoningByModel[AIProvider.openRouter.rawValue]?["model-b"] == .high, "Resetting A does not change B")
        check(explicitlyReset.defaultReasoningMode(for: "model-b", provider: .openRouter, availableModes: [.modelDefault]) == .modelDefault, "Temporarily unavailable efforts use Auto")
        check(explicitlyReset.defaultReasoningMode(for: "model-b", provider: .openRouter, availableModes: [.modelDefault, .high]) == .high, "Restoring capabilities restores the remembered effort")
        var inheritedCommands = restartedStore.load()
        for index in inheritedCommands.commands.indices { inheritedCommands.commands[index].useDefaultReasoning = false }
        check(restartedStore.migrateCommandReasoningInheritance(in: &inheritedCommands), "Enable inheritance for existing commands on first migration")
        check(inheritedCommands.commands.allSatisfy(\.useDefaultReasoning), "Every existing command inherits the menu effort")
        restartedStore.save(inheritedCommands)
        inheritedCommands.commands[0].useDefaultReasoning = false
        restartedStore.save(inheritedCommands)
        var explicitOverride = restartedStore.load()
        check(!restartedStore.migrateCommandReasoningInheritance(in: &explicitOverride), "Inheritance migration runs only once")
        check(!explicitOverride.commands[0].useDefaultReasoning && explicitOverride.commands.dropFirst().allSatisfy(\.useDefaultReasoning), "A later explicit command override stays independent")

        let pendingPopup = ResultPopupState(result: CommandExecutionResult(commandTitle: "Test", model: "test-model", output: "", originalSelection: "", captureSource: .accessibility, target: ExternalApplicationTarget(bundleIdentifier: nil, processIdentifier: 0, localizedName: "Test"), commandID: "test", selectionRestoreAnchor: nil), isStreaming: true)
        check(!pendingPopup.canApply, "A processing popup must not replace a selection with empty text")
        pendingPopup.result.output = "Result"
        check(pendingPopup.canApply, "Apply becomes available once actual output exists")

        // Verify KeychainStore round-trip, plaintext JSON migration, and secret scrubbing.
        let keychainService = "Homer.daydream.tests.\(UUID().uuidString)"
        let testKeychain = KeychainStore(service: keychainService)
        defer { testKeychain.removeAll() }
        let secretDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "Homer.daydream.tests.\(secretDir.lastPathComponent)")
            try? FileManager.default.removeItem(at: secretDir)
        }
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
        check(migratedSecrets.openRouterAPIKey == "test-or-secret", "Migrate OpenRouter API key to Keychain")
        check(migratedSecrets.deepSeekAPIKey == "test-ds-secret", "Migrate DeepSeek API key to Keychain")
        check(testKeychain.string(for: .openRouterAPIKey) == "test-or-secret", "Persist migrated secret in macOS Keychain")
        check(!FileManager.default.fileExists(atPath: secretSettingsURL.path), "Remove legacy settings.json after migrating to UserDefaults plist")
        let storedPlistData = keychainSettingsStore.storedSettingsDataForTesting()!
        let scrubbedJSON = try JSONSerialization.jsonObject(with: storedPlistData) as! [String: Any]
        check(scrubbedJSON["apiKey"] == nil && scrubbedJSON["openRouterAPIKey"] == nil && scrubbedJSON["deepSeekAPIKey"] == nil && scrubbedJSON["tavilyAPIKey"] == nil, "Scrub all API keys from UserDefaults plist storage")
        let reloadedFromKeychain = SettingsStore(directory: secretDir, credentialStore: testKeychain).load()
        check(reloadedFromKeychain.openRouterAPIKey == "test-or-secret" && reloadedFromKeychain.deepSeekAPIKey == "test-ds-secret", "Restore API keys from Keychain on restart")
        migratedSecrets.openRouterAPIKey = ""
        keychainSettingsStore.save(migratedSecrets)
        check(testKeychain.string(for: .openRouterAPIKey) == nil, "Clearing an API key deletes it from Keychain")

        // Verify corrupted settings.json is backed up and never overwritten with defaults.
        let corruptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "Homer.daydream.tests.\(corruptDir.lastPathComponent)")
            try? FileManager.default.removeItem(at: corruptDir)
        }
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

        // Verify SettingsStore UserDefaults plist persistence and preservation of uninstalled third-party IME rules.
        let inputStoreDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: "Homer.daydream.tests.\(inputStoreDir.lastPathComponent)")
            try? FileManager.default.removeItem(at: inputStoreDir)
        }
        let localInputStore = SettingsStore(directory: inputStoreDir)
        var localInputSettings = AppSettings.default
        localInputSettings.inputSourceSwitchingEnabled = false
        localInputSettings.defaultEnglishInputSourceID = "com.apple.keylayout.US"
        localInputSettings.appInputSourceRules = [
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
        localInputStore.save(localInputSettings)
        let rawLocalInputJSON = try JSONSerialization.jsonObject(with: localInputStore.storedSettingsDataForTesting()!) as! [String: Any]
        check(
            rawLocalInputJSON["defaultEnglishInputSourceID"] as? String == "com.apple.keylayout.US" &&
            rawLocalInputJSON["appInputSourceRules"] != nil,
            "UserDefaults plist persists defaultEnglishInputSourceID and appInputSourceRules"
        )
        let reloadedInputStore = SettingsStore(directory: inputStoreDir)
        let reloadedInputSettings = reloadedInputStore.load()
        check(
            reloadedInputSettings.inputSourceSwitchingEnabled == false,
            "Reloading SettingsStore preserves inputSourceSwitchingEnabled == false from UserDefaults plist"
        )
        reloadedInputStore.save(reloadedInputSettings)
        let roundTrippedLocalSettings = reloadedInputStore.load()
        check(
            roundTrippedLocalSettings.appInputSourceRules.contains(where: {
                $0.bundleIdentifier == "com.tencent.xinWeChat" &&
                $0.inputSourceID == "com.apple.inputmethod.SCIM.ITABC"
            }) &&
            roundTrippedLocalSettings.appInputSourceRules.contains(where: {
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

        try await runWindowMoverTests()

        print("Provider model, discovery, migration, Keychain, SQLite FTS5, Obsidian, Input Source Switching, Window Mover, and single-file iCloud query checks passed")
    }

    private static func runWindowMoverTests() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
        }
        let primaryMaxY: CGFloat = 1_440
        let lg1 = ScreenGeometry(
            name: "LG UltraFine (1)",
            accessibilityFrame: ScreenGeometry.accessibilityFrame(
                from: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
                primaryScreenMaxY: primaryMaxY
            ),
            accessibilityVisibleFrame: ScreenGeometry.accessibilityFrame(
                from: CGRect(x: 0, y: 0, width: 2_506, height: 1_410),
                primaryScreenMaxY: primaryMaxY
            )
        )
        let builtIn = ScreenGeometry(
            name: "Built-in Retina Display",
            accessibilityFrame: ScreenGeometry.accessibilityFrame(
                from: CGRect(x: -401, y: -982, width: 1_512, height: 982),
                primaryScreenMaxY: primaryMaxY
            ),
            accessibilityVisibleFrame: ScreenGeometry.accessibilityFrame(
                from: CGRect(x: -401, y: -982, width: 1_512, height: 950),
                primaryScreenMaxY: primaryMaxY
            )
        )
        let lg2 = ScreenGeometry(
            name: "LG UltraFine (2)",
            accessibilityFrame: ScreenGeometry.accessibilityFrame(
                from: CGRect(x: -2_304, y: 0, width: 2_304, height: 1_296),
                primaryScreenMaxY: primaryMaxY
            ),
            accessibilityVisibleFrame: ScreenGeometry.accessibilityFrame(
                from: CGRect(x: -2_304, y: 0, width: 2_304, height: 1_296),
                primaryScreenMaxY: primaryMaxY
            )
        )

        check(
            lg1.accessibilityFrame == CGRect(x: 0, y: 0, width: 2_560, height: 1_440) &&
            lg1.accessibilityVisibleFrame == CGRect(x: 0, y: 30, width: 2_506, height: 1_410) &&
            builtIn.accessibilityFrame == CGRect(x: -401, y: 1_440, width: 1_512, height: 982) &&
            builtIn.accessibilityVisibleFrame == CGRect(x: -401, y: 1_472, width: 1_512, height: 950) &&
            lg2.accessibilityFrame == CGRect(x: -2_304, y: 144, width: 2_304, height: 1_296) &&
            lg2.accessibilityVisibleFrame == CGRect(x: -2_304, y: 144, width: 2_304, height: 1_296),
            "ScreenGeometry converts AppKit rects to Quartz/AX top-left coordinates"
        )

        let ordered = WindowMoverService.orderedScreens(from: [lg1, builtIn, lg2])
        check(
            ordered.map(\.name) == ["LG UltraFine (2)", "Built-in Retina Display", "LG UltraFine (1)"],
            "orderedScreens sorts displays deterministically by minX then minY"
        )

        let fastTiming = WindowMoverTimingConfiguration(
            pollInterval: .milliseconds(5),
            exitFullScreenTimeout: .milliseconds(120),
            enterFullScreenTimeout: .milliseconds(120),
            targetScreenSettleTimeout: .milliseconds(40),
            preFullScreenEntrySettleDelay: .milliseconds(5),
            actionRetryInterval: .milliseconds(25),
            requiredStablePolls: 3
        )

        // 1. Standard window move + oversized clamping + maximized window on secondary display
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, builtIn, lg2])
            let app = WindowTargetApp(processIdentifier: 101, bundleIdentifier: "com.apple.optimus", localizedName: "Optimus")
            backend.frontmostApp = app
            let win = backend.makeWindow(
                id: 1,
                frame: CGRect(x: 500, y: 230, width: 1_200, height: 800),
                fullScreen: false
            )
            backend.focusedElement = win

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            let firstMove = try await service.moveFocusedWindowToNextScreen()
            check(
                firstMove == WindowMoveResult(
                    applicationName: "Optimus",
                    sourceScreenName: "LG UltraFine (1)",
                    targetScreenName: "LG UltraFine (2)",
                    mode: .standard
                ),
                "Standard window on LG 1 wraps around to LG 2"
            )
            check(
                backend.windowsByID[1]?.frame.size == CGSize(width: 1_200, height: 800) &&
                backend.setSizeCalls.isEmpty &&
                backend.setFullScreenCalls.isEmpty,
                "Standard window that fits target preserves exact size with zero resize or fullscreen calls"
            )

            // Oversized window (2200x1300) moving from LG 2 (2304x1296) -> Built-in (1512x950 visible)
            backend.windowsByID[1]?.frame = CGRect(x: -2_250, y: 144, width: 2_200, height: 1_296)
            backend.postMoveSizeDrift = CGSize(width: 1_600, height: 980)
            let clampedMove = try await service.moveFocusedWindowToNextScreen()
            check(
                clampedMove == WindowMoveResult(
                    applicationName: "Optimus",
                    sourceScreenName: "LG UltraFine (2)",
                    targetScreenName: "Built-in Retina Display",
                    mode: .standard
                ),
                "Oversized desktop window moves from LG 2 to Built-in"
            )
            let landedFrame = backend.windowsByID[1]!.frame
            check(
                landedFrame == CGRect(x: -401, y: 1_472, width: 1_512, height: 950) &&
                WindowMoverService.screenIndex(containing: landedFrame, in: ordered) == 1,
                "size -> position -> size clamps oversized window into Built-in visibleFrame and fixes post-move size drift"
            )

            // Maximized standard window on LG 2 (where accessibilityFrame == accessibilityVisibleFrame) stays .standard
            backend.windowsByID[1]?.frame = lg2.accessibilityFrame
            let maximizedMove = try await service.moveFocusedWindowToNextScreen()
            check(
                maximizedMove.mode == .standard &&
                backend.windowsByID[1]?.frame == builtIn.accessibilityVisibleFrame,
                "Maximized AXStandardWindow on display without menu bar stays .standard and respects target notch inset"
            )
        }

        // 2. Borderless / non-native fullscreen move across all 3 displays (including chrome-free LG 2)
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, builtIn, lg2])
            let app = WindowTargetApp(processIdentifier: 102, bundleIdentifier: "com.googlecode.iterm2", localizedName: "iTerm2")
            backend.frontmostApp = app
            let win = backend.makeWindow(
                id: 2,
                frame: lg1.accessibilityFrame,
                fullScreen: false,
                hasFullScreenButton: false,
                hasStandardButtons: false
            )
            backend.focusedElement = win

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            let result1 = try await service.moveFocusedWindowToNextScreen()
            check(
                result1.mode == .borderlessFullScreen &&
                backend.windowsByID[2]?.frame == lg2.accessibilityFrame &&
                backend.setFullScreenCalls.isEmpty,
                "Borderless fullscreen window covering menu bar/Dock relocates directly to LG 2 full frame"
            )

            // Second press from chrome-free LG 2 (frame == visibleFrame) to notched Built-in STILL stays .borderlessFullScreen
            let result2 = try await service.moveFocusedWindowToNextScreen()
            check(
                result2.mode == .borderlessFullScreen &&
                backend.windowsByID[2]?.frame == builtIn.accessibilityFrame &&
                backend.setFullScreenCalls.isEmpty,
                "Borderless fullscreen window without titlebar buttons stays .borderlessFullScreen on chrome-free display"
            )
        }

        // 3. Native Fullscreen 3-display cycle + AXEnhancedUserInterface save/restore + transient focus retention
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, builtIn, lg2])
            let chrome = WindowTargetApp(processIdentifier: 201, bundleIdentifier: "com.google.Chrome", localizedName: "Google Chrome")
            let finder = WindowTargetApp(processIdentifier: 202, bundleIdentifier: "com.apple.finder", localizedName: "Finder")
            backend.frontmostApp = chrome
            backend.enhancedUIEnabledByPID[chrome.processIdentifier] = true

            let win = backend.makeWindow(
                id: 10,
                frame: lg1.accessibilityFrame,
                restoredDesktopFrame: CGRect(x: 220, y: 120, width: 1_738, height: 1_038),
                fullScreen: true,
                exitTransitionTicks: 3,
                enterTransitionTicks: 2
            )
            backend.focusedElement = win
            backend.transientFrontmostSwitchDuringExit = finder

            let service = WindowMoverService(backend: backend, timing: fastTiming)

            // Move 1: LG 1 -> LG 2
            let move1 = try await service.moveFocusedWindowToNextScreen()
            check(
                move1 == WindowMoveResult(
                    applicationName: "Google Chrome",
                    sourceScreenName: "LG UltraFine (1)",
                    targetScreenName: "LG UltraFine (2)",
                    mode: .nativeFullScreen
                ),
                "Native fullscreen window moves from LG 1 to LG 2"
            )
            check(
                backend.windowsByID[10]?.fullScreen == true &&
                backend.windowsByID[10]?.isPositionSettable == false &&
                WindowMoverService.screenIndex(containing: backend.windowsByID[10]!.frame, in: ordered) == 0 &&
                backend.enhancedUIEnabledByPID[chrome.processIdentifier] == true &&
                backend.enhancedUICalls == [false, true] &&
                backend.activatedPIDs.contains(chrome.processIdentifier) &&
                !service.isMoveInProgress,
                "Native fullscreen move re-enters fullscreen on LG 2, restores AXEnhancedUserInterface, and re-activates drifted app"
            )

            // Move 2: LG 2 -> Built-in Retina Display
            let move2 = try await service.moveFocusedWindowToNextScreen()
            check(
                move2 == WindowMoveResult(
                    applicationName: "Google Chrome",
                    sourceScreenName: "LG UltraFine (2)",
                    targetScreenName: "Built-in Retina Display",
                    mode: .nativeFullScreen
                ) &&
                backend.windowsByID[10]?.fullScreen == true &&
                WindowMoverService.screenIndex(containing: backend.windowsByID[10]!.frame, in: ordered) == 1,
                "Native fullscreen window moves from LG 2 to smaller Built-in display and re-enters fullscreen on Built-in"
            )

            // Move 3: Built-in Retina Display (notched fullscreen frame) -> LG 1
            let move3 = try await service.moveFocusedWindowToNextScreen()
            check(
                move3 == WindowMoveResult(
                    applicationName: "Google Chrome",
                    sourceScreenName: "Built-in Retina Display",
                    targetScreenName: "LG UltraFine (1)",
                    mode: .nativeFullScreen
                ) &&
                backend.windowsByID[10]?.fullScreen == true &&
                WindowMoverService.screenIndex(containing: backend.windowsByID[10]!.frame, in: ordered) == 2,
                "Native fullscreen window completes 3-display cycle back to LG 1"
            )
        }

        // 4. Focused window unwrapping (NSToolbarFullScreenWindow, floating palette, AXMainWindow/AXWindows fallbacks, Finder Desktop rejection)
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, lg2])
            let safari = WindowTargetApp(processIdentifier: 301, bundleIdentifier: "com.apple.Safari", localizedName: "Safari")
            backend.frontmostApp = safari

            let fsWindow = backend.makeWindow(
                id: 20,
                frame: lg1.accessibilityFrame,
                restoredDesktopFrame: CGRect(x: 200, y: 120, width: 1_280, height: 820),
                fullScreen: true,
                exitTransitionTicks: 1,
                enterTransitionTicks: 1
            )
            let toolbarGroup = backend.makeElement(
                id: 21,
                role: kAXGroupRole as String,
                subrole: nil,
                containingWindow: fsWindow
            )
            backend.focusedElement = toolbarGroup
            backend.mainElement = fsWindow

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            let toolbarMove = try await service.moveFocusedWindowToNextScreen()
            check(
                toolbarMove.mode == .nativeFullScreen &&
                toolbarMove.targetScreenName == "LG UltraFine (2)" &&
                backend.windowsByID[20]?.fullScreen == true,
                "Unwraps NSToolbarFullScreenWindow (AXGroup) to underlying fullscreen AXWindow"
            )

            // Floating palette focused while mainWindow is fullscreen on LG 2
            let floatingPanel = backend.makeWindow(
                id: 22,
                subrole: kAXFloatingWindowSubrole as String,
                frame: CGRect(x: -1_800, y: 220, width: 320, height: 240),
                fullScreen: false
            )
            backend.focusedElement = floatingPanel
            backend.mainElement = fsWindow
            let paletteMove = try await service.moveFocusedWindowToNextScreen()
            check(
                paletteMove.mode == .nativeFullScreen &&
                paletteMove.targetScreenName == "LG UltraFine (1)",
                "Prefers fullscreen mainWindow when focused element is a non-fullscreen floating auxiliary panel"
            )

            // focusedWindow == nil and mainWindow == nil -> falls back to AXWindows skipping AXScrollArea Desktop and minimized windows
            let desktopScrollArea = backend.makeElement(
                id: 23,
                role: kAXScrollAreaRole as String,
                subrole: nil,
                containingWindow: nil
            )
            let minimizedWin = backend.makeWindow(
                id: 24,
                frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                fullScreen: false,
                minimized: true
            )
            backend.focusedElement = nil
            backend.mainElement = nil
            backend.windowList = [desktopScrollArea, minimizedWin, fsWindow]
            let fallbackMove = try await service.moveFocusedWindowToNextScreen()
            check(
                fallbackMove.mode == .nativeFullScreen &&
                fallbackMove.targetScreenName == "LG UltraFine (2)",
                "Falls back to AXWindows selecting fullscreen AXWindow while skipping AXScrollArea and minimized windows"
            )

            // Finder with only Desktop AXScrollArea throws .noFocusedWindow
            backend.windowList = [desktopScrollArea]
            var noWindowError: WindowMoverError?
            do {
                _ = try await service.moveFocusedWindowToNextScreen()
            } catch let error as WindowMoverError {
                noWindowError = error
            }
            check(
                noWindowError == .noFocusedWindow("Safari"),
                "Rejects Desktop AXScrollArea when no real AXWindow exists"
            )
        }

        // 5. Button fallback, .cannotComplete non-double-toggle, and delayed _fullScreenContentController re-entry retry
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, lg2])
            let customApp = WindowTargetApp(processIdentifier: 401, bundleIdentifier: "example.custom", localizedName: "CustomApp")
            backend.frontmostApp = customApp
            let win = backend.makeWindow(
                id: 30,
                frame: lg1.accessibilityFrame,
                restoredDesktopFrame: CGRect(x: 300, y: 150, width: 1_100, height: 760),
                fullScreen: true,
                isFullScreenSettable: false,
                hasFullScreenButton: true,
                exitTransitionTicks: 1,
                enterTransitionTicks: 1
            )
            backend.focusedElement = win

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            let buttonFallbackMove = try await service.moveFocusedWindowToNextScreen()
            check(
                buttonFallbackMove.mode == .nativeFullScreen &&
                backend.buttonPressSubroleChecks == [false, true] &&
                backend.windowsByID[30]?.fullScreen == true,
                "Falls back to AXFullScreenButton press (requireFullScreenSubrole=false on exit, true on entry) when AXFullScreen is not settable"
            )

            // .cannotComplete on exit + first setFullScreen(true) dropped silently by AppKit teardown lag
            backend.buttonPressSubroleChecks.removeAll()
            backend.windowsByID[30]?.isFullScreenSettable = true
            backend.returnCannotCompleteOnExit = true
            backend.dropNextFullScreenEntryCount = 1

            let retryMove = try await service.moveFocusedWindowToNextScreen()
            check(
                retryMove.targetScreenName == "LG UltraFine (1)" &&
                backend.buttonPressSubroleChecks.isEmpty &&
                backend.setFullScreenCalls.filter({ $0 == true }).count == 2 &&
                backend.windowsByID[30]?.fullScreen == true,
                "Treats .cannotComplete exit as initiated without button double-toggle and retries dropped setFullScreen(true) after backoff"
            )
        }

        // 6. Modal sheet blocker, unsupported kiosk fullscreen, and timeout cleanup invariants
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, lg2])
            let app = WindowTargetApp(processIdentifier: 501, bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit")
            backend.frontmostApp = app
            backend.enhancedUIEnabledByPID[app.processIdentifier] = true
            let win = backend.makeWindow(
                id: 40,
                frame: lg1.accessibilityFrame,
                restoredDesktopFrame: CGRect(x: 200, y: 150, width: 900, height: 700),
                fullScreen: true
            )
            backend.windowsByID[40]?.hasModalSheet = true
            backend.focusedElement = win

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            var sheetError: WindowMoverError?
            do {
                _ = try await service.moveFocusedWindowToNextScreen()
            } catch let error as WindowMoverError {
                sheetError = error
            }
            check(
                sheetError == .fullScreenExitBlockedByModalSheet("TextEdit") &&
                backend.setFullScreenCalls.isEmpty,
                "Attached modal sheet fails fast before toggling AXFullScreen"
            )

            // Kiosk window that neither allows setting AXFullScreen nor has a fullscreen button
            backend.windowsByID[40]?.hasModalSheet = false
            backend.windowsByID[40]?.isFullScreenSettable = false
            backend.windowsByID[40]?.hasFullScreenButton = false
            var kioskError: WindowMoverError?
            do {
                _ = try await service.moveFocusedWindowToNextScreen()
            } catch let error as WindowMoverError {
                kioskError = error
            }
            check(
                kioskError == .fullScreenExitUnsupported("TextEdit"),
                "Kiosk fullscreen window without AX exit capability throws .fullScreenExitUnsupported"
            )

            // Stalled re-entry timeout still restores AXEnhancedUserInterface and clears isMoveInProgress
            backend.windowsByID[40]?.isFullScreenSettable = true
            backend.windowsByID[40]?.hasFullScreenButton = true
            backend.dropNextFullScreenEntryCount = 99
            backend.ignoreButtonPressOnEntry = true
            var timeoutError: WindowMoverError?
            do {
                _ = try await service.moveFocusedWindowToNextScreen()
            } catch let error as WindowMoverError {
                timeoutError = error
            }
            check(
                timeoutError == .fullScreenReentryTimedOut("TextEdit") &&
                backend.enhancedUIEnabledByPID[app.processIdentifier] == true &&
                !service.isMoveInProgress,
                "Re-entry timeout restores AXEnhancedUserInterface and resets isMoveInProgress"
            )
        }

        // 7. Re-entrancy serialization under rapid shortcut presses
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, lg2])
            let app = WindowTargetApp(processIdentifier: 601, bundleIdentifier: "com.apple.optimus", localizedName: "Optimus")
            backend.frontmostApp = app
            let win = backend.makeWindow(
                id: 50,
                frame: lg1.accessibilityFrame,
                restoredDesktopFrame: CGRect(x: 200, y: 120, width: 1_200, height: 800),
                fullScreen: true,
                exitTransitionTicks: 1,
                enterTransitionTicks: 1
            )
            backend.focusedElement = win
            backend.pauseOnFirstSleep = true

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            let firstTask = Task { @MainActor in
                try await service.moveFocusedWindowToNextScreen()
            }

            while !backend.isPausedOnSleep {
                await Task.yield()
            }
            check(service.isMoveInProgress, "First move marks isMoveInProgress while awaiting fullscreen exit")

            var concurrentError: WindowMoverError?
            do {
                _ = try await service.moveFocusedWindowToNextScreen()
            } catch let error as WindowMoverError {
                concurrentError = error
            }
            check(
                concurrentError == .moveAlreadyInProgress &&
                backend.setFullScreenCalls == [false],
                "Concurrent shortcut press rejects with .moveAlreadyInProgress without issuing duplicate AXFullScreen calls"
            )

            backend.resumePausedSleep()
            let firstResult = try await firstTask.value
            check(
                firstResult.targetScreenName == "LG UltraFine (2)" && !service.isMoveInProgress,
                "First in-flight move finishes cleanly after concurrent rejection"
            )

            let subsequentResult = try await service.moveFocusedWindowToNextScreen()
            check(
                subsequentResult.targetScreenName == "LG UltraFine (1)",
                "Subsequent move succeeds once previous fullscreen transition finishes"
            )
        }

        // 8. Adversarial edge cases: sibling window isolation, transient IPC errors, EnhancedUI .cannotComplete restore, non-resizable oversized centering, Step A rollback, notched bottom-Dock fallback, and non-movable child AXWindow unwrapping
        do {
            let backend = MockWindowMoverBackend(screens: [lg1, builtIn, lg2])
            let app = WindowTargetApp(processIdentifier: 701, bundleIdentifier: "com.google.Chrome", localizedName: "Google Chrome")
            backend.frontmostApp = app
            backend.enhancedUIEnabledByPID[app.processIdentifier] = true
            backend.returnCannotCompleteOnDisableEnhancedUI = true
            backend.transientIPCErrorPollsOnReentry = 2

            let targetWin = backend.makeWindow(
                id: 60,
                frame: lg1.accessibilityFrame,
                restoredDesktopFrame: CGRect(x: 150, y: 120, width: 1_400, height: 900),
                fullScreen: true,
                exitTransitionTicks: 1,
                enterTransitionTicks: 2
            )
            let siblingFullScreenWin = backend.makeWindow(
                id: 61,
                frame: lg2.accessibilityFrame,
                restoredDesktopFrame: CGRect(x: -1_900, y: 200, width: 1_200, height: 800),
                fullScreen: true
            )
            backend.focusedElement = targetWin
            backend.replaceInvalidatedWindowDuringExit = (oldID: 60, newID: 62)

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            let result = try await service.moveFocusedWindowToNextScreen()
            check(
                result.targetScreenName == "LG UltraFine (2)" &&
                backend.windowsByID[61]?.fullScreen == true &&
                backend.windowsByID[62]?.fullScreen == true &&
                backend.enhancedUIEnabledByPID[app.processIdentifier] == true,
                "Re-acquires replacement window without touching pre-existing sibling fullscreen window, survives transient .cannotComplete IPC polls on re-entry, and restores EnhancedUI after .cannotComplete disable"
            )
            _ = siblingFullScreenWin
        }

        do {
            // Non-movable child AXWindow (subrole AXUnknown) unwraps to fullscreen mainWindow; notched Built-in with bottom Dock (.attributeUnsupported); Step A rollback on setPosition failure; oversized non-resizable centering
            let notchedBottomDock = ScreenGeometry(
                name: "Built-in Bottom Dock",
                accessibilityFrame: CGRect(x: -401, y: 1_440, width: 1_512, height: 982),
                accessibilityVisibleFrame: CGRect(x: -401, y: 1_472, width: 1_512, height: 880)
            )
            let backend = MockWindowMoverBackend(screens: [lg1, notchedBottomDock])
            let app = WindowTargetApp(processIdentifier: 801, bundleIdentifier: "example.notched", localizedName: "NotchedApp")
            backend.frontmostApp = app

            let fsMain = backend.makeWindow(
                id: 70,
                frame: CGRect(x: -401, y: 1_472, width: 1_512, height: 950),
                restoredDesktopFrame: CGRect(x: -300, y: 1_500, width: 1_200, height: 800),
                fullScreen: true,
                exitTransitionTicks: 1,
                enterTransitionTicks: 1
            )
            backend.returnAttributeUnsupportedForFullScreen = true
            let childToolbarWin = backend.makeWindow(
                id: 71,
                subrole: "AXUnknown",
                frame: CGRect(x: -401, y: 1_440, width: 1_512, height: 32),
                fullScreen: false
            )
            backend.windowsByID[71]?.isPositionSettable = false
            backend.focusedElement = childToolbarWin
            backend.mainElement = fsMain

            let service = WindowMoverService(backend: backend, timing: fastTiming)
            let notchedMove = try await service.moveFocusedWindowToNextScreen()
            check(
                notchedMove.mode == .nativeFullScreen &&
                notchedMove.targetScreenName == "LG UltraFine (1)",
                "Unwraps non-movable AXUnknown child window to mainWindow and classifies notched+bottom-Dock fullscreen via spansFullScreenBand"
            )

            // Step A size rollback when setPosition fails
            backend.returnAttributeUnsupportedForFullScreen = false
            let desktopOversized = backend.makeWindow(
                id: 72,
                frame: CGRect(x: 100, y: 100, width: 2_200, height: 1_300),
                fullScreen: false
            )
            backend.focusedElement = desktopOversized
            backend.mainElement = desktopOversized
            backend.failNextSetPositionError = .cannotComplete
            var failedMoveError: WindowMoverError?
            do {
                _ = try await service.moveFocusedWindowToNextScreen()
            } catch let error as WindowMoverError {
                failedMoveError = error
            }
            check(
                failedMoveError == .moveFailed(.cannotComplete) &&
                backend.windowsByID[72]?.frame.size == CGSize(width: 2_200, height: 1_300),
                "Rolls back pre-move setSize when setPosition fails"
            )

            // Non-resizable 2400x2000 window moving onto smaller Built-in (1512x880 visible, stacked below LG 1) centers X and Y so Built-in wins intersection
            backend.windowsByID[72]?.frame = CGRect(x: 80, y: 30, width: 2_400, height: 2_000)
            backend.windowsByID[72]?.isSizeSettable = false
            let nonResizableMove = try await service.moveFocusedWindowToNextScreen()
            let orderedPair = WindowMoverService.orderedScreens(from: [lg1, notchedBottomDock])
            let finalNonResizableFrame = backend.windowsByID[72]!.frame
            check(
                nonResizableMove.targetScreenName == "Built-in Bottom Dock" &&
                WindowMoverService.screenIndex(containing: finalNonResizableFrame, in: orderedPair) == 0,
                "Centers oversized non-resizable window on both axes so smaller target display retains maximum intersection area"
            )
        }
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

@MainActor
private final class MockWindowMoverBackend: WindowMoverBackend {
    struct MockWindowState {
        var id: Int
        var role: String
        var subrole: String?
        var containingWindow: WindowElementHandle?
        var frame: CGRect
        var restoredDesktopFrame: CGRect
        var fullScreen: Bool
        var isPositionSettable: Bool
        var isSizeSettable: Bool
        var isFullScreenSettable: Bool
        var hasFullScreenButton: Bool
        var hasStandardButtons: Bool
        var minimized: Bool
        var isMain: Bool
        var hasModalSheet: Bool
        var exitTransitionTicks: Int
        var enterTransitionTicks: Int
    }

    private enum PendingTransition {
        case exiting(windowID: Int, remainingTicks: Int)
        case entering(windowID: Int, remainingTicks: Int)
    }

    var accessibilityTrusted = true
    var frontmostApp: WindowTargetApp? {
        didSet {
            if let frontmostApp {
                appsByPID[frontmostApp.processIdentifier] = frontmostApp
            }
        }
    }
    var appsByPID: [pid_t: WindowTargetApp] = [:]
    var screenList: [ScreenGeometry]
    var focusedElement: WindowElementHandle?
    var mainElement: WindowElementHandle?
    var windowList: [WindowElementHandle] = []
    var windowsByID: [Int: MockWindowState] = [:]
    var enhancedUIEnabledByPID: [pid_t: Bool] = [:]

    var setSizeCalls: [CGSize] = []
    var setPositionCalls: [CGPoint] = []
    var setFullScreenCalls: [Bool] = []
    var enhancedUICalls: [Bool] = []
    var activatedPIDs: [pid_t] = []
    var buttonPressSubroleChecks: [Bool] = []

    var postMoveSizeDrift: CGSize?
    var transientFrontmostSwitchDuringExit: WindowTargetApp?
    var returnCannotCompleteOnExit = false
    var returnCannotCompleteOnDisableEnhancedUI = false
    var returnAttributeUnsupportedForFullScreen = false
    var transientIPCErrorPollsOnReentry = 0
    var replaceInvalidatedWindowDuringExit: (oldID: Int, newID: Int)?
    var failNextSetPositionError: AXError?
    var dropNextFullScreenEntryCount = 0
    var ignoreButtonPressOnEntry = false
    var pauseOnFirstSleep = false
    private(set) var isPausedOnSleep = false

    private var pendingTransition: PendingTransition?
    private var sleepContinuation: CheckedContinuation<Void, Never>?

    init(screens: [ScreenGeometry]) {
        self.screenList = screens
    }

    func makeWindow(
        id: Int,
        subrole: String? = kAXStandardWindowSubrole as String,
        frame: CGRect,
        restoredDesktopFrame: CGRect? = nil,
        fullScreen: Bool,
        isSizeSettable: Bool = true,
        isFullScreenSettable: Bool = true,
        hasFullScreenButton: Bool = true,
        hasStandardButtons: Bool = true,
        minimized: Bool = false,
        isMain: Bool = true,
        exitTransitionTicks: Int = 2,
        enterTransitionTicks: Int = 2
    ) -> WindowElementHandle {
        let handle = WindowElementHandle(storage: .mock(id: id))
        windowsByID[id] = MockWindowState(
            id: id,
            role: kAXWindowRole as String,
            subrole: subrole,
            containingWindow: nil,
            frame: frame,
            restoredDesktopFrame: restoredDesktopFrame ?? frame,
            fullScreen: fullScreen,
            isPositionSettable: !fullScreen,
            isSizeSettable: isSizeSettable,
            isFullScreenSettable: isFullScreenSettable,
            hasFullScreenButton: hasFullScreenButton,
            hasStandardButtons: hasStandardButtons,
            minimized: minimized,
            isMain: isMain,
            hasModalSheet: false,
            exitTransitionTicks: exitTransitionTicks,
            enterTransitionTicks: enterTransitionTicks
        )
        windowList.append(handle)
        return handle
    }

    func makeElement(
        id: Int,
        role: String,
        subrole: String?,
        containingWindow: WindowElementHandle?
    ) -> WindowElementHandle {
        let handle = WindowElementHandle(storage: .mock(id: id))
        windowsByID[id] = MockWindowState(
            id: id,
            role: role,
            subrole: subrole,
            containingWindow: containingWindow,
            frame: .zero,
            restoredDesktopFrame: .zero,
            fullScreen: false,
            isPositionSettable: false,
            isSizeSettable: false,
            isFullScreenSettable: false,
            hasFullScreenButton: false,
            hasStandardButtons: false,
            minimized: false,
            isMain: false,
            hasModalSheet: false,
            exitTransitionTicks: 0,
            enterTransitionTicks: 0
        )
        return handle
    }

    func resumePausedSleep() {
        isPausedOnSleep = false
        let continuation = sleepContinuation
        sleepContinuation = nil
        continuation?.resume()
    }

    func isAccessibilityTrusted() -> Bool {
        accessibilityTrusted
    }

    func frontmostApplication() -> WindowTargetApp? {
        frontmostApp
    }

    @discardableResult
    func activateApplication(processIdentifier: pid_t) -> Bool {
        activatedPIDs.append(processIdentifier)
        if let current = frontmostApp, current.processIdentifier != processIdentifier {
            frontmostApp = appsByPID[processIdentifier] ?? WindowTargetApp(
                processIdentifier: processIdentifier,
                bundleIdentifier: nil,
                localizedName: "RestoredApp"
            )
        }
        return true
    }

    func screens() -> [ScreenGeometry] {
        screenList
    }

    func focusedWindowOrElement(of processIdentifier: pid_t) -> WindowElementHandle? {
        focusedElement
    }

    func mainWindow(of processIdentifier: pid_t) -> WindowElementHandle? {
        mainElement
    }

    func windows(of processIdentifier: pid_t) -> [WindowElementHandle] {
        windowList
    }

    func role(of element: WindowElementHandle) -> String? {
        guard case .mock(let id) = element.storage else { return nil }
        return windowsByID[id]?.role
    }

    func subrole(of element: WindowElementHandle) -> String? {
        guard case .mock(let id) = element.storage else { return nil }
        return windowsByID[id]?.subrole
    }

    func containingWindow(of element: WindowElementHandle) -> WindowElementHandle? {
        guard case .mock(let id) = element.storage else { return nil }
        return windowsByID[id]?.containingWindow
    }

    func isMinimized(_ window: WindowElementHandle) -> Bool {
        guard case .mock(let id) = window.storage else { return false }
        return windowsByID[id]?.minimized ?? false
    }

    func isMain(_ window: WindowElementHandle) -> Bool {
        guard case .mock(let id) = window.storage else { return false }
        return windowsByID[id]?.isMain ?? false
    }

    func hasAttachedModalSheet(_ window: WindowElementHandle) -> Bool {
        guard case .mock(let id) = window.storage else { return false }
        return windowsByID[id]?.hasModalSheet ?? false
    }

    func hasStandardWindowButtons(_ window: WindowElementHandle) -> Bool {
        guard case .mock(let id) = window.storage else { return false }
        return windowsByID[id]?.hasStandardButtons ?? false
    }

    func frame(of window: WindowElementHandle) -> AccessibilityValueResult<CGRect> {
        if case .entering = pendingTransition, transientIPCErrorPollsOnReentry > 0 {
            return .failure(.cannotComplete)
        }
        guard case .mock(let id) = window.storage, let state = windowsByID[id] else {
            return .failure(.invalidUIElement)
        }
        return .success(state.frame)
    }

    func positionSettability(
        _ window: WindowElementHandle
    ) -> AccessibilityValueResult<Bool> {
        if case .entering = pendingTransition, transientIPCErrorPollsOnReentry > 0 {
            return .failure(.cannotComplete)
        }
        guard case .mock(let id) = window.storage, let state = windowsByID[id] else {
            return .failure(.invalidUIElement)
        }
        return .success(state.isPositionSettable)
    }

    func isSizeSettable(_ window: WindowElementHandle) -> Bool {
        guard case .mock(let id) = window.storage else { return false }
        return windowsByID[id]?.isSizeSettable ?? false
    }

    func setPosition(_ origin: CGPoint, of window: WindowElementHandle) -> AXError {
        if let error = failNextSetPositionError {
            failNextSetPositionError = nil
            return error
        }
        guard case .mock(let id) = window.storage, var state = windowsByID[id] else {
            return .invalidUIElement
        }
        guard state.isPositionSettable else {
            return .failure
        }
        setPositionCalls.append(origin)
        state.frame.origin = origin
        if let drift = postMoveSizeDrift {
            postMoveSizeDrift = nil
            state.frame.size = drift
        }
        state.restoredDesktopFrame = state.frame
        windowsByID[id] = state
        return .success
    }

    func setSize(_ size: CGSize, of window: WindowElementHandle) -> AXError {
        guard case .mock(let id) = window.storage, var state = windowsByID[id] else {
            return .invalidUIElement
        }
        guard state.isSizeSettable else {
            return .failure
        }
        setSizeCalls.append(size)
        state.frame.size = size
        state.restoredDesktopFrame = state.frame
        windowsByID[id] = state
        return .success
    }

    @discardableResult
    func raiseWindow(_ window: WindowElementHandle) -> AXError {
        .success
    }

    func fullScreenState(of window: WindowElementHandle) -> AccessibilityValueResult<Bool> {
        if case .entering = pendingTransition, transientIPCErrorPollsOnReentry > 0 {
            transientIPCErrorPollsOnReentry -= 1
            return .failure(.cannotComplete)
        }
        guard case .mock(let id) = window.storage, let state = windowsByID[id] else {
            return .failure(.invalidUIElement)
        }
        if returnAttributeUnsupportedForFullScreen {
            return .failure(.attributeUnsupported)
        }
        return .success(state.fullScreen)
    }

    func isFullScreenSettable(_ window: WindowElementHandle) -> Bool {
        if returnAttributeUnsupportedForFullScreen {
            return false
        }
        guard case .mock(let id) = window.storage else { return false }
        return windowsByID[id]?.isFullScreenSettable ?? false
    }

    func setFullScreen(_ fullScreen: Bool, of window: WindowElementHandle) -> AXError {
        guard case .mock(let id) = window.storage, let state = windowsByID[id] else {
            return .invalidUIElement
        }
        guard state.isFullScreenSettable, !returnAttributeUnsupportedForFullScreen else {
            return .attributeUnsupported
        }
        setFullScreenCalls.append(fullScreen)
        if fullScreen == state.fullScreen {
            return .success
        }
        if !fullScreen {
            scheduleExitTransition(for: id, ticks: state.exitTransitionTicks)
            if returnCannotCompleteOnExit {
                returnCannotCompleteOnExit = false
                return .cannotComplete
            }
            return .success
        } else {
            if dropNextFullScreenEntryCount > 0 {
                dropNextFullScreenEntryCount -= 1
                return .success
            }
            scheduleEnterTransition(for: id, ticks: state.enterTransitionTicks)
            return .success
        }
    }

    func pressFullScreenButton(of window: WindowElementHandle, requireFullScreenSubrole: Bool) -> AXError {
        guard case .mock(let id) = window.storage, let state = windowsByID[id] else {
            return .invalidUIElement
        }
        guard state.hasFullScreenButton else {
            return .noValue
        }
        buttonPressSubroleChecks.append(requireFullScreenSubrole)
        if state.fullScreen {
            scheduleExitTransition(for: id, ticks: state.exitTransitionTicks)
        } else if !ignoreButtonPressOnEntry {
            scheduleEnterTransition(for: id, ticks: state.enterTransitionTicks)
        }
        return .success
    }

    func hasFullScreenCapableButton(_ window: WindowElementHandle) -> Bool {
        guard case .mock(let id) = window.storage else { return false }
        return windowsByID[id]?.hasFullScreenButton ?? false
    }

    func isEnhancedUserInterfaceEnabled(for processIdentifier: pid_t) -> Bool {
        enhancedUIEnabledByPID[processIdentifier] ?? false
    }

    @discardableResult
    func setEnhancedUserInterface(_ enabled: Bool, for processIdentifier: pid_t) -> AXError {
        enhancedUICalls.append(enabled)
        enhancedUIEnabledByPID[processIdentifier] = enabled
        if !enabled, returnCannotCompleteOnDisableEnhancedUI {
            returnCannotCompleteOnDisableEnhancedUI = false
            return .cannotComplete
        }
        return .success
    }

    func sleep(_ duration: Duration) async throws {
        if pauseOnFirstSleep {
            pauseOnFirstSleep = false
            isPausedOnSleep = true
            await withCheckedContinuation { continuation in
                self.sleepContinuation = continuation
            }
        }
        advanceTransitionTick()
    }

    private func scheduleExitTransition(for windowID: Int, ticks: Int) {
        if let switched = transientFrontmostSwitchDuringExit {
            transientFrontmostSwitchDuringExit = nil
            frontmostApp = switched
        }
        var targetWindowID = windowID
        if let replacement = replaceInvalidatedWindowDuringExit, replacement.oldID == windowID,
           var migrated = windowsByID.removeValue(forKey: replacement.oldID) {
            replaceInvalidatedWindowDuringExit = nil
            migrated.id = replacement.newID
            windowsByID[replacement.newID] = migrated
            let newHandle = WindowElementHandle(storage: .mock(id: replacement.newID))
            windowList.removeAll { $0 == WindowElementHandle(storage: .mock(id: replacement.oldID)) }
            windowList.append(newHandle)
            focusedElement = nil
            mainElement = nil
            targetWindowID = replacement.newID
        }
        pendingTransition = .exiting(windowID: targetWindowID, remainingTicks: max(1, ticks))
    }

    private func scheduleEnterTransition(for windowID: Int, ticks: Int) {
        pendingTransition = .entering(windowID: windowID, remainingTicks: max(1, ticks))
    }

    private func advanceTransitionTick() {
        guard let transition = pendingTransition else { return }
        switch transition {
        case .exiting(let windowID, let remainingTicks):
            guard var state = windowsByID[windowID] else {
                pendingTransition = nil
                return
            }
            if remainingTicks > 1 {
                state.fullScreen = false
                state.isPositionSettable = true
                state.frame = CGRect(
                    x: state.restoredDesktopFrame.minX + CGFloat(remainingTicks * 12),
                    y: state.restoredDesktopFrame.minY + CGFloat(remainingTicks * 8),
                    width: state.restoredDesktopFrame.width + CGFloat(remainingTicks * 20),
                    height: state.restoredDesktopFrame.height + CGFloat(remainingTicks * 14)
                )
                windowsByID[windowID] = state
                pendingTransition = .exiting(windowID: windowID, remainingTicks: remainingTicks - 1)
            } else {
                state.fullScreen = false
                state.isPositionSettable = true
                state.frame = state.restoredDesktopFrame
                windowsByID[windowID] = state
                pendingTransition = nil
            }

        case .entering(let windowID, let remainingTicks):
            if transientIPCErrorPollsOnReentry > 0 {
                return
            }
            guard var state = windowsByID[windowID] else {
                pendingTransition = nil
                return
            }
            let ordered = WindowMoverService.orderedScreens(from: screenList)
            let ownerIndex = WindowMoverService.screenIndex(containing: state.frame, in: ordered)
            let ownerScreen = ordered[ownerIndex]
            let targetFullScreenFrame = ownerScreen.name.hasPrefix("Built-in")
                ? CGRect(
                    x: ownerScreen.accessibilityFrame.minX,
                    y: ownerScreen.accessibilityVisibleFrame.minY,
                    width: ownerScreen.accessibilityFrame.width,
                    height: ownerScreen.accessibilityFrame.maxY - ownerScreen.accessibilityVisibleFrame.minY
                )
                : ownerScreen.accessibilityFrame

            if remainingTicks > 1 {
                state.fullScreen = true
                state.isPositionSettable = false
                state.frame = CGRect(
                    x: targetFullScreenFrame.minX + 10,
                    y: targetFullScreenFrame.minY + 10,
                    width: targetFullScreenFrame.width - 20,
                    height: targetFullScreenFrame.height - 20
                )
                windowsByID[windowID] = state
                pendingTransition = .entering(windowID: windowID, remainingTicks: remainingTicks - 1)
            } else {
                state.fullScreen = true
                state.isPositionSettable = false
                state.frame = targetFullScreenFrame
                windowsByID[windowID] = state
                pendingTransition = nil
            }
        }
    }
}


