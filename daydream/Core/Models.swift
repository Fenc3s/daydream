import AppKit
import ApplicationServices
import Carbon
import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var provider: AIProvider
    var reasoningByModel: [String: ReasoningMode] = [:]
    var reasoningEffortOverrides: [String: [String: [ReasoningMode]]] = [:]
    var defaultReasoningByModel: [String: [String: ReasoningMode]] = [:]
    var openRouterBaseURL: String
    var openRouterAPIKey: String
    var deepSeekBaseURL: String
    var deepSeekAPIKey: String
    var chatGPTBaseURL: String
    var providerModelCatalogs: [String: [String]]
    var defaultModel: String
    var providerDefaultModels: [String: String]
    var clipboardHistoryShortcut: KeyboardShortcut?
    var moveWindowShortcut: KeyboardShortcut
    var clipboardHistoryRetention: ClipboardHistoryRetention
    var memoryEnabled: Bool
    var memoryLimit: Int
    var iCloudPasswordsDiaAutomationEnabled: Bool
    var inputSourceSwitchingEnabled: Bool = true
    var defaultEnglishInputSourceID: String? = nil
    var appInputSourceRules: [AppInputSourceRule] = []
    var obsidianVaultName: String
    var obsidianSubfolder: String
    var commands: [AICommand]

    static let defaultObsidianVaultName = "Obsidian Vault"

    static let retiredModelCatalog: Set<String> = [
        "gemini-3-flash-preview:latest",
        "openai/gpt-5.4-nano",
        "openai/gpt-5.4-mini",
        "openai/gpt-5.4",
        "openai/gpt-5.5",
        "google/gemini-3.1-flash-lite",
        "google/gemini-3.5-flash",
    ]

    static let defaultOpenRouterModelCatalog = [
        "google/gemini-3.6-flash",
        "google/gemini-3.5-flash-lite",
        "openai/gpt-5.6-luna",
        "openai/gpt-5.6-terra",
        "openai/gpt-5.6-sol",
        "anthropic/claude-haiku-4.5",
        "anthropic/claude-sonnet-4.6"
    ]

    static let deepSeekFlashModel = "deepseek-v4-flash"
    static let deepSeekProModel = "deepseek-v4-pro"
    static let deepSeekModelCatalog = [
        deepSeekFlashModel,
        deepSeekProModel
    ]

    static let chatGPTDefaultModel = "gpt-5.4"
    static let defaultChatGPTModelCatalog = [
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-4o"
    ]

    static let openRouterDefaultModel = "google/gemini-3.5-flash-lite"
    static let deepSeekDefaultModel = deepSeekFlashModel
    static let defaultMoveWindowShortcut = KeyboardShortcut(
        keyCode: UInt16(kVK_ANSI_D),
        modifiers: [.command, .option]
    )
    static let `default` = AppSettings(
        provider: .openRouter,
        openRouterBaseURL: "https://openrouter.ai/api/v1",
        openRouterAPIKey: "",
        deepSeekBaseURL: "https://api.deepseek.com",
        deepSeekAPIKey: "",
        chatGPTBaseURL: "https://api.openai.com/v1",
        providerModelCatalogs: defaultProviderModelCatalogs,
        defaultModel: openRouterDefaultModel,
        providerDefaultModels: defaultProviderDefaultModels,
        clipboardHistoryShortcut: nil,
        moveWindowShortcut: defaultMoveWindowShortcut,
        clipboardHistoryRetention: .oneMonth,
        memoryEnabled: true,
        memoryLimit: 80,
        iCloudPasswordsDiaAutomationEnabled: true,
        obsidianVaultName: defaultObsidianVaultName,
        obsidianSubfolder: "",
        commands: AICommand.defaultCommands
    )

    enum CodingKeys: String, CodingKey {
        case provider
        case reasoningByModel
        case reasoningEffortOverrides
        case defaultReasoningByModel
        case openRouterBaseURL
        case openRouterAPIKey
        case deepSeekBaseURL
        case deepSeekAPIKey
        case chatGPTBaseURL
        case providerModelCatalogs
        case defaultModel
        case providerDefaultModels
        case clipboardHistoryShortcut
        case moveWindowShortcut
        case clipboardHistoryRetention
        case memoryEnabled
        case memoryLimit
        case iCloudPasswordsDiaAutomationEnabled
        case inputSourceSwitchingEnabled
        case defaultEnglishInputSourceID
        case appInputSourceRules
        case obsidianVaultName
        case obsidianSubfolder
        case commands
    }

    init(
        provider: AIProvider,
        openRouterBaseURL: String,
        openRouterAPIKey: String,
        deepSeekBaseURL: String,
        deepSeekAPIKey: String,
        chatGPTBaseURL: String = "https://api.openai.com/v1",
        providerModelCatalogs: [String: [String]],
        defaultModel: String,
        providerDefaultModels: [String: String],
        clipboardHistoryShortcut: KeyboardShortcut?,
        moveWindowShortcut: KeyboardShortcut,
        clipboardHistoryRetention: ClipboardHistoryRetention,
        memoryEnabled: Bool,
        memoryLimit: Int,
        iCloudPasswordsDiaAutomationEnabled: Bool,
        obsidianVaultName: String = defaultObsidianVaultName,
        obsidianSubfolder: String = "",
        commands: [AICommand]
    ) {
        self.provider = provider
        self.openRouterBaseURL = openRouterBaseURL
        self.openRouterAPIKey = openRouterAPIKey
        self.deepSeekBaseURL = deepSeekBaseURL
        self.deepSeekAPIKey = deepSeekAPIKey
        self.chatGPTBaseURL = chatGPTBaseURL
        self.providerModelCatalogs = Self.normalizedProviderModelCatalogs(providerModelCatalogs)
        self.defaultModel = defaultModel
        self.providerDefaultModels = Self.normalizedProviderDefaultModels(
            providerDefaultModels,
            selectedProvider: provider,
            selectedDefaultModel: defaultModel,
            providerModelCatalogs: self.providerModelCatalogs
        )
        self.clipboardHistoryShortcut = clipboardHistoryShortcut
        self.moveWindowShortcut = moveWindowShortcut
        self.clipboardHistoryRetention = clipboardHistoryRetention
        self.memoryEnabled = memoryEnabled
        self.memoryLimit = Self.normalizedMemoryLimit(memoryLimit)
        self.iCloudPasswordsDiaAutomationEnabled = iCloudPasswordsDiaAutomationEnabled
        self.obsidianVaultName = obsidianVaultName
        self.obsidianSubfolder = obsidianSubfolder
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultReasoningByModel = try container.decodeIfPresent([String: [String: ReasoningMode]].self, forKey: .defaultReasoningByModel) ?? [:]
        reasoningEffortOverrides = try container.decodeIfPresent([String: [String: [ReasoningMode]]].self, forKey: .reasoningEffortOverrides) ?? [:]
        reasoningByModel = try container.decodeIfPresent([String: ReasoningMode].self, forKey: .reasoningByModel) ?? [:]
        let decodedProvider = try container.decodeIfPresent(String.self, forKey: .provider)
        provider = decodedProvider.flatMap(AIProvider.init(rawValue:)) ?? .openRouter
        openRouterBaseURL = try container.decodeIfPresent(String.self, forKey: .openRouterBaseURL) ?? Self.default.openRouterBaseURL
        openRouterAPIKey = try container.decodeIfPresent(String.self, forKey: .openRouterAPIKey) ?? ""
        deepSeekBaseURL = try container.decodeIfPresent(String.self, forKey: .deepSeekBaseURL) ?? Self.default.deepSeekBaseURL
        deepSeekAPIKey = try container.decodeIfPresent(String.self, forKey: .deepSeekAPIKey) ?? ""
        chatGPTBaseURL = try container.decodeIfPresent(String.self, forKey: .chatGPTBaseURL) ?? Self.default.chatGPTBaseURL
        let decodedProviderModelCatalogs = try container.decodeIfPresent([String: [String]].self, forKey: .providerModelCatalogs)
            ?? Self.defaultProviderModelCatalogs
        providerModelCatalogs = Self.normalizedProviderModelCatalogs(decodedProviderModelCatalogs)
        let decodedDefaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? Self.defaultModel(for: provider)
        let decodedProviderDefaultModels = try container.decodeIfPresent([String: String].self, forKey: .providerDefaultModels) ?? [:]
        providerDefaultModels = Self.normalizedProviderDefaultModels(
            decodedProviderDefaultModels,
            selectedProvider: provider,
            selectedDefaultModel: decodedDefaultModel,
            providerModelCatalogs: providerModelCatalogs
        )
        let catalogForProvider = Self.modelCatalog(for: provider, providerModelCatalogs: providerModelCatalogs)
        defaultModel = catalogForProvider.contains(decodedDefaultModel)
            ? decodedDefaultModel
            : (providerDefaultModels[provider.rawValue] ?? Self.defaultModel(for: provider))
        clipboardHistoryShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .clipboardHistoryShortcut)
        moveWindowShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .moveWindowShortcut)
            ?? Self.defaultMoveWindowShortcut
        clipboardHistoryRetention = try container.decodeIfPresent(ClipboardHistoryRetention.self, forKey: .clipboardHistoryRetention) ?? .oneMonth
        memoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        memoryLimit = Self.normalizedMemoryLimit(try container.decodeIfPresent(Int.self, forKey: .memoryLimit) ?? Self.default.memoryLimit)
        iCloudPasswordsDiaAutomationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .iCloudPasswordsDiaAutomationEnabled
        ) ?? true
        inputSourceSwitchingEnabled = try container.decodeIfPresent(Bool.self, forKey: .inputSourceSwitchingEnabled) ?? true
        defaultEnglishInputSourceID = Self.normalizedOptionalIdentifier(
            try container.decodeIfPresent(String.self, forKey: .defaultEnglishInputSourceID)
        )
        appInputSourceRules = Self.normalizedAppInputSourceRules(
            try container.decodeIfPresent([AppInputSourceRule].self, forKey: .appInputSourceRules) ?? []
        )
        obsidianVaultName = try container.decodeIfPresent(String.self, forKey: .obsidianVaultName) ?? Self.defaultObsidianVaultName
        obsidianSubfolder = try container.decodeIfPresent(String.self, forKey: .obsidianSubfolder) ?? ""
        commands = try container.decodeIfPresent([AICommand].self, forKey: .commands) ?? AICommand.defaultCommands
    }

    func defaultReasoningMode(for model: String, provider: AIProvider, availableModes: [ReasoningMode]) -> ReasoningMode {
        let mode = defaultReasoningByModel[provider.rawValue]?[model] ?? .modelDefault
        return availableModes.contains(mode) ? mode : .modelDefault
    }

    mutating func setDefaultReasoningMode(_ mode: ReasoningMode, for model: String, provider: AIProvider) {
        defaultReasoningByModel[provider.rawValue, default: [:]][model] = mode
    }

    func manualReasoningEfforts(for model: String, provider: AIProvider) -> [ReasoningMode]? {
        reasoningEffortOverrides[provider.rawValue]?[model]
    }

    mutating func setManualReasoningEfforts(_ efforts: [ReasoningMode]?, for model: String, provider: AIProvider) {
        if let efforts {
            let normalized = ReasoningMode.allCases.filter { $0.effort != nil && efforts.contains($0) }
            reasoningEffortOverrides[provider.rawValue, default: [:]][model] = normalized
        } else {
            reasoningEffortOverrides[provider.rawValue]?[model] = nil
            if reasoningEffortOverrides[provider.rawValue]?.isEmpty == true {
                reasoningEffortOverrides[provider.rawValue] = nil
            }
        }
    }

    static func normalizedMemoryLimit(_ limit: Int) -> Int {
        min(max(limit, 10), 500)
    }

    static func normalizedOptionalIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static let spotlightBundleIdentifier = "com.apple.Spotlight"

    static let spotlightHostBundleIdentifiers: Set<String> = [
        "com.apple.Spotlight",
    ]

    static let systemIgnoredBundleIdentifiers: Set<String> = {
        var identifiers: Set<String> = [
            "Homer.daydream",
            "com.apple.systemuiserver",
            "com.apple.loginwindow",
            "com.apple.SecurityAgent",
            "com.apple.controlcenter",
            "com.apple.notificationcenterui",
        ]
        if let mainBundleIdentifier = normalizedOptionalIdentifier(Bundle.main.bundleIdentifier) {
            identifiers.insert(mainBundleIdentifier)
        }
        identifiers.subtract(spotlightHostBundleIdentifiers)
        return identifiers
    }()

    static func normalizedAppInputSourceRules(_ rules: [AppInputSourceRule]) -> [AppInputSourceRule] {
        let ignoredBundleIdentifiers = systemIgnoredBundleIdentifiers
        var seenBundleIdentifiers: Set<String> = []
        return rules.compactMap { rule in
            guard let trimmedBundleID = normalizedOptionalIdentifier(rule.bundleIdentifier),
                  let inputSourceID = normalizedOptionalIdentifier(rule.inputSourceID) else {
                return nil
            }
            let bundleIdentifier = trimmedBundleID
            guard !ignoredBundleIdentifiers.contains(bundleIdentifier),
                  seenBundleIdentifiers.insert(bundleIdentifier).inserted else {
                return nil
            }
            let trimmedAppName = normalizedOptionalIdentifier(rule.appName)
            let appName: String
            if bundleIdentifier == spotlightBundleIdentifier,
               trimmedAppName == nil
                || trimmedAppName == "Siri"
                || trimmedAppName == spotlightBundleIdentifier {
                appName = "Spotlight"
            } else {
                appName = trimmedAppName ?? bundleIdentifier
            }
            return AppInputSourceRule(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                inputSourceID: inputSourceID,
                isEnabled: rule.isEnabled
            )
        }
    }

    static func normalizedModels(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return trimmed
        }
    }

    static var defaultProviderModelCatalogs: [String: [String]] {
        [
            AIProvider.openRouter.rawValue: defaultOpenRouterModelCatalog,
            AIProvider.deepSeek.rawValue: deepSeekModelCatalog,
            AIProvider.chatGPT.rawValue: defaultChatGPTModelCatalog,
        ]
    }

    static func normalizedProviderModelCatalogs(_ catalogs: [String: [String]]) -> [String: [String]] {
        var normalized = defaultProviderModelCatalogs
        for provider in AIProvider.allCases {
            let models = normalizedModels(catalogs[provider.rawValue] ?? [])
            if !models.isEmpty {
                normalized[provider.rawValue] = models
            }
        }
        return normalized
    }

    static func modelCatalog(
        for provider: AIProvider,
        providerModelCatalogs: [String: [String]] = defaultProviderModelCatalogs
    ) -> [String] {
        let models = normalizedModels(providerModelCatalogs[provider.rawValue] ?? [])
        return models.isEmpty ? defaultProviderModelCatalogs[provider.rawValue]! : models
    }

    func modelCatalog(for provider: AIProvider) -> [String] {
        Self.modelCatalog(for: provider, providerModelCatalogs: providerModelCatalogs)
    }

    static func defaultModel(for provider: AIProvider) -> String {
        switch provider {
        case .openRouter:
            return openRouterDefaultModel
        case .deepSeek:
            return deepSeekDefaultModel
        case .chatGPT:
            return chatGPTDefaultModel
        }
    }

    static var defaultProviderDefaultModels: [String: String] {
        Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { provider in
            (provider.rawValue, defaultModel(for: provider))
        })
    }

    static func normalizedProviderDefaultModels(
        _ models: [String: String],
        selectedProvider: AIProvider,
        selectedDefaultModel: String,
        providerModelCatalogs: [String: [String]] = defaultProviderModelCatalogs
    ) -> [String: String] {
        var normalized: [String: String] = [:]
        for provider in AIProvider.allCases {
            let catalog = modelCatalog(for: provider, providerModelCatalogs: providerModelCatalogs)
            let builtInDefault = defaultModel(for: provider)
            normalized[provider.rawValue] = catalog.contains(builtInDefault) ? builtInDefault : catalog[0]

            let model = models[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if catalog.contains(model) {
                normalized[provider.rawValue] = model
            }
        }

        let selectedModel = selectedDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedCatalog = modelCatalog(for: selectedProvider, providerModelCatalogs: providerModelCatalogs)
        let storedSelectedModel = models[selectedProvider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if selectedCatalog.contains(selectedModel), !selectedCatalog.contains(storedSelectedModel) {
            normalized[selectedProvider.rawValue] = selectedModel
        }
        return normalized
    }

    func defaultModel(for provider: AIProvider) -> String {
        let model = providerDefaultModels[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let catalog = modelCatalog(for: provider)
        if catalog.contains(model) {
            return model
        }
        let builtInDefault = Self.defaultModel(for: provider)
        return catalog.contains(builtInDefault) ? builtInDefault : catalog[0]
    }

    mutating func setDefaultModel(_ model: String, for provider: AIProvider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelCatalog(for: provider).contains(trimmed) else { return }
        providerDefaultModels[provider.rawValue] = trimmed
        if provider == self.provider {
            defaultModel = trimmed
        }
    }
}

enum AIProvider: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case openRouter = "OpenRouter"
    case deepSeek = "DeepSeek"
    case chatGPT = "ChatGPT"

    var id: String { rawValue }

    var displayName: String { rawValue }
}

enum ReasoningMode: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case disabled
    case modelDefault
    case noEffort = "none"
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var effort: String? {
        switch self {
        case .noEffort, .minimal, .low, .medium, .high, .xhigh, .max:
            rawValue
        case .disabled, .modelDefault:
            nil
        }
    }

    var displayName: String {
        switch self {
        case .disabled:
            "Off"
        case .modelDefault:
            "Auto"
        case .noEffort:
            "None"
        case .minimal:
            "Minimal"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        case .xhigh:
            "Extra High"
        case .max:
            "Max"
        }
    }
}

struct AICommand: Identifiable, Codable, Equatable, Sendable {
    let stableID: UUID
    var commandID: String
    var title: String
    var promptTemplate: String
    var shortcut: KeyboardShortcut?
    var modelOverride: String?
    var reasoningMode: ReasoningMode
    var useDefaultReasoning: Bool
    var showPopup: Bool
    var saveToObsidian: Bool

    init(
        stableID: UUID = UUID(),
        commandID: String,
        title: String,
        promptTemplate: String,
        shortcut: KeyboardShortcut? = nil,
        modelOverride: String? = nil,
        reasoningMode: ReasoningMode = .disabled,
        useDefaultReasoning: Bool = true,
        showPopup: Bool = true,
        saveToObsidian: Bool = false
    ) {
        self.stableID = stableID
        self.commandID = commandID
        self.title = title
        self.promptTemplate = promptTemplate
        self.shortcut = shortcut
        self.modelOverride = modelOverride
        self.reasoningMode = reasoningMode
        self.useDefaultReasoning = useDefaultReasoning
        self.showPopup = showPopup
        self.saveToObsidian = saveToObsidian
    }

    var id: UUID { stableID }

    var resolvedModel: String? {
        guard let modelOverride, !modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return modelOverride
    }

    func effectiveModel(defaultModel: String) -> String {
        resolvedModel ?? defaultModel
    }

    private static let tokenExpression = try! NSRegularExpression(
        pattern: #"\{\{(text|command_title|app_name|clipboard|date)\}\}"#
    )

    func renderPrompt(
        with text: String,
        appName: String = "",
        clipboardText: String = "",
        date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: date)

        let values: [String: String] = [
            "text": text,
            "command_title": title,
            "app_name": appName,
            "clipboard": clipboardText,
            "date": dateString,
        ]

        let matches = Self.tokenExpression.matches(
            in: promptTemplate,
            range: NSRange(promptTemplate.startIndex..., in: promptTemplate)
        )
        guard !matches.isEmpty else { return promptTemplate }

        var rendered = ""
        var cursor = promptTemplate.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: promptTemplate),
                  let keyRange = Range(match.range(at: 1), in: promptTemplate) else {
                continue
            }
            rendered += promptTemplate[cursor..<fullRange.lowerBound]
            let key = String(promptTemplate[keyRange])
            rendered += values[key] ?? String(promptTemplate[fullRange])
            cursor = fullRange.upperBound
        }
        rendered += promptTemplate[cursor...]
        return rendered
    }

    enum CodingKeys: String, CodingKey {
        case stableID
        case commandID = "id"
        case title
        case promptTemplate
        case shortcut
        case modelOverride = "model"
        case reasoningMode
        case useDefaultReasoning
        case reasoningEnabled
        case showPopup
        case saveToObsidian
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stableID = try container.decodeIfPresent(UUID.self, forKey: .stableID) ?? UUID()
        commandID = try container.decode(String.self, forKey: .commandID)
        title = try container.decode(String.self, forKey: .title)
        promptTemplate = try container.decode(String.self, forKey: .promptTemplate)
        shortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .shortcut)
        modelOverride = try container.decodeIfPresent(String.self, forKey: .modelOverride)
        if let reasoningMode = try container.decodeIfPresent(ReasoningMode.self, forKey: .reasoningMode) {
            self.reasoningMode = reasoningMode
        } else {
            let reasoningEnabled = try container.decodeIfPresent(Bool.self, forKey: .reasoningEnabled) ?? false
            reasoningMode = reasoningEnabled ? .modelDefault : .disabled
        }
        useDefaultReasoning = try container.decodeIfPresent(Bool.self, forKey: .useDefaultReasoning) ?? false
        showPopup = try container.decodeIfPresent(Bool.self, forKey: .showPopup) ?? true
        if container.contains(.saveToObsidian) {
            saveToObsidian = try container.decode(Bool.self, forKey: .saveToObsidian)
        } else {
            saveToObsidian = commandID == "define-word"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableID, forKey: .stableID)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(title, forKey: .title)
        try container.encode(promptTemplate, forKey: .promptTemplate)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
        try container.encodeIfPresent(modelOverride, forKey: .modelOverride)
        try container.encode(reasoningMode, forKey: .reasoningMode)
        try container.encode(useDefaultReasoning, forKey: .useDefaultReasoning)
        try container.encode(showPopup, forKey: .showPopup)
        try container.encode(saveToObsidian, forKey: .saveToObsidian)
    }

    static let defaultCommands: [AICommand] = [
        AICommand(
            commandID: "define-word",
            title: "Define Word",
            promptTemplate: """
            Provide the pronunciation and detailed definitions of {{text}}. For each meaning, include a bilingual explanation (English + Chinese), and a bilingual example sentence on the same line with the word {{text}} highlighted in bold. Then, list the word’s synonyms and antonyms (with Chinese translations), and etymology (with Chinese explanation). Present everything in a obsidian friendly markdown format. Start with: 
            ---
            tags:
              - "#vocab"
            links:
              - "[[Vocabulary Overview]]"
            ---

            Command: {{command_title}}

            Text:
            {{text}}
            """,
            saveToObsidian: true
        ),
        AICommand(
            commandID: "translate-en",
            title: "Translate to English",
            promptTemplate: """
            Translate {{text}} to English.
            Fixing any spelling and grammar errors
            Rephrase the sentence to make it more fluent and closer to native expression(If necessary)
            Do not return anything other than the translated text. Do not wrap responses in quotes.

            Command: {{command_title}}

            Text:
            {{text}}
            """
        ),
        AICommand(
            commandID: "translate-zh",
            title: "Translate to Chinese",
            promptTemplate: """
            Translate {{text}} to Chinese.
            Fixing any spelling and grammar errors
            Rephrase the sentence to make it more fluent and closer to native expression(If necessary)
            Do not return anything other than the translated text. Do not wrap responses in quotes.

            Command: {{command_title}}

            Text:
            {{text}}
            """
        ),
        AICommand(
            commandID: "summarize",
            title: "Summarize",
            promptTemplate: """
            You are a concise writing assistant.
            Summarize the following content in clear bullet points.

            Command: {{command_title}}

            Text:
            {{text}}
            """
        ),
    ]

    static func makeNew(index: Int) -> AICommand {
        AICommand(
            commandID: "command-\(index)",
            title: "New Command \(index)",
            promptTemplate: """
            Process the following text.

            Command: {{command_title}}

            Text:
            {{text}}
            """
        )
    }
}

struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: ShortcutModifiers

    var displayString: String {
        modifiers.symbols + (Self.keyLabel(for: keyCode) ?? "?")
    }

    var registrationKey: String {
        "\(keyCode)-\(modifiers.rawValue)"
    }

    var hasPrimaryModifier: Bool {
        modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.control)
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    static func capture(from event: NSEvent) -> KeyboardShortcut? {
        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard Self.keyLabel(for: UInt16(event.keyCode)) != nil else {
            return nil
        }
        return KeyboardShortcut(keyCode: UInt16(event.keyCode), modifiers: modifiers)
    }

    static func keyLabel(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Equal: return "+"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return nil
        }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let control = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var shortcutFlags: ShortcutModifiers = []
        if flags.contains(.command) { shortcutFlags.insert(.command) }
        if flags.contains(.option) { shortcutFlags.insert(.option) }
        if flags.contains(.control) { shortcutFlags.insert(.control) }
        if flags.contains(.shift) { shortcutFlags.insert(.shift) }
        self = shortcutFlags
    }

    var symbols: String {
        var output = ""
        if contains(.control) { output += "⌃" }
        if contains(.option) { output += "⌥" }
        if contains(.shift) { output += "⇧" }
        if contains(.command) { output += "⌘" }
        return output
    }
}

enum SelectionCaptureSource: String, Codable, Equatable {
    case accessibility
    case clipboardFallback
}

struct ExternalApplicationTarget: Equatable, Sendable {
    var bundleIdentifier: String?
    var processIdentifier: pid_t
    var localizedName: String

    var displayName: String {
        localizedName.isEmpty ? (bundleIdentifier ?? "Unknown App") : localizedName
    }
}

struct SelectionRestoreAnchor: @unchecked Sendable {
    var element: AXUIElement
    var selectedRange: NSRange
}

struct CapturedSelection: Sendable {
    var text: String
    var source: SelectionCaptureSource
    var target: ExternalApplicationTarget
    var restoreAnchor: SelectionRestoreAnchor?
}

struct CommandExecutionResult: Identifiable, Sendable {
    let id = UUID()
    var commandTitle: String
    var model: String
    var output: String
    var originalSelection: String
    var captureSource: SelectionCaptureSource
    var target: ExternalApplicationTarget
    var commandID: String
    var selectionRestoreAnchor: SelectionRestoreAnchor?
}

struct ClipboardHistoryEntry: Identifiable, Codable {
    var id = UUID()
    var capturedAt: Date
    var sourceAppName: String
    var sourceAppBundleIdentifier: String?
    var contentType: ClipboardContentType
    var title: String
    var subtitle: String?
    var plainText: String?
    var imageData: Data?
    var imagePreview: NSImage?
    var fileURLs: [URL]
    var snapshot: PasteboardSnapshot
    var fingerprint: String

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt
        case sourceAppName
        case sourceAppBundleIdentifier
        case contentType
        case title
        case subtitle
        case plainText
        case imageData
        case legacyImagePNGData = "imagePNGData"
        case fileURLs
        case snapshot
        case fingerprint
    }

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        sourceAppName: String,
        sourceAppBundleIdentifier: String? = nil,
        contentType: ClipboardContentType,
        title: String,
        subtitle: String?,
        plainText: String?,
        imageData: Data? = nil,
        imagePreview: NSImage?,
        fileURLs: [URL],
        snapshot: PasteboardSnapshot,
        fingerprint: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceAppName = sourceAppName
        self.sourceAppBundleIdentifier = sourceAppBundleIdentifier
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.plainText = plainText
        self.imageData = imageData
        self.imagePreview = imagePreview
        self.fileURLs = fileURLs
        self.snapshot = snapshot
        self.fingerprint = fingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        let sourceAppName = try container.decode(String.self, forKey: .sourceAppName)
        let sourceAppBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceAppBundleIdentifier)
        let contentType = try container.decode(ClipboardContentType.self, forKey: .contentType)
        let title = try container.decode(String.self, forKey: .title)
        let subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        let plainText = try container.decodeIfPresent(String.self, forKey: .plainText)
        let imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        let legacyImageData = try container.decodeIfPresent(Data.self, forKey: .legacyImagePNGData)
        let fileURLs = try container.decode([URL].self, forKey: .fileURLs)
        let snapshot = try container.decode(PasteboardSnapshot.self, forKey: .snapshot)
        let fingerprint = try container.decode(String.self, forKey: .fingerprint)
        let resolvedImageData = imageData ?? legacyImageData
        let imagePreview = resolvedImageData.flatMap(NSImage.init(data:))

        self.init(
            id: id,
            capturedAt: capturedAt,
            sourceAppName: sourceAppName,
            sourceAppBundleIdentifier: sourceAppBundleIdentifier,
            contentType: contentType,
            title: title,
            subtitle: subtitle,
            plainText: plainText,
            imageData: resolvedImageData,
            imagePreview: imagePreview,
            fileURLs: fileURLs,
            snapshot: snapshot,
            fingerprint: fingerprint
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(sourceAppName, forKey: .sourceAppName)
        try container.encodeIfPresent(sourceAppBundleIdentifier, forKey: .sourceAppBundleIdentifier)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(plainText, forKey: .plainText)
        try container.encodeIfPresent(imageData, forKey: .imageData)
        try container.encode(fileURLs, forKey: .fileURLs)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(fingerprint, forKey: .fingerprint)
    }
}

struct ClipboardHistorySummary: Identifiable, Codable, Equatable {
    var id: UUID
    var capturedAt: Date
    var sourceAppName: String
    var sourceAppBundleIdentifier: String?
    var contentType: ClipboardContentType
    var title: String
    var subtitle: String?
    var plainText: String?
    var fileURLs: [URL]
    var fingerprint: String

    init(
        id: UUID,
        capturedAt: Date,
        sourceAppName: String,
        sourceAppBundleIdentifier: String?,
        contentType: ClipboardContentType,
        title: String,
        subtitle: String?,
        plainText: String?,
        fileURLs: [URL],
        fingerprint: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceAppName = sourceAppName
        self.sourceAppBundleIdentifier = sourceAppBundleIdentifier
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.plainText = plainText
        self.fileURLs = fileURLs
        self.fingerprint = fingerprint
    }
}

extension ClipboardHistoryEntry {
    var summary: ClipboardHistorySummary {
        ClipboardHistorySummary(
            id: id,
            capturedAt: capturedAt,
            sourceAppName: sourceAppName,
            sourceAppBundleIdentifier: sourceAppBundleIdentifier,
            contentType: contentType,
            title: title,
            subtitle: subtitle,
            plainText: plainText,
            fileURLs: fileURLs,
            fingerprint: fingerprint
        )
    }
}

enum ClipboardContentType: String, CaseIterable, Identifiable, Codable {
    case all = "All Types"
    case text = "Text"
    case link = "Links"
    case file = "Files"
    case image = "Images"
    case other = "Other"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var iconName: String {
        switch self {
        case .all:
            return "line.3.horizontal.decrease.circle"
        case .text:
            return "doc.text"
        case .link:
            return "link"
        case .file:
            return "doc"
        case .image:
            return "photo"
        case .other:
            return "square.on.square"
        }
    }
}

enum ClipboardHistoryRetention: String, CaseIterable, Codable, Identifiable {
    case oneWeek = "1 Week"
    case oneMonth = "1 Month"
    case oneYear = "1 Year"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var maxAge: TimeInterval {
        switch self {
        case .oneWeek:
            return 7 * 24 * 60 * 60
        case .oneMonth:
            return 30 * 24 * 60 * 60
        case .oneYear:
            return 365 * 24 * 60 * 60
        }
    }
}

struct KeyboardInputSource: Identifiable, Equatable, Sendable {
    var id: String
    var localizedName: String
    var sourceType: String
    var isASCIICapable: Bool
    var languages: [String]
}

struct AppInputSourceRule: Identifiable, Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var appName: String
    var inputSourceID: String
    var isEnabled: Bool

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        appName: String,
        inputSourceID: String,
        isEnabled: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.inputSourceID = inputSourceID
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case appName
        case inputSourceID
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? ""
        inputSourceID = try container.decode(String.self, forKey: .inputSourceID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(appName, forKey: .appName)
        try container.encode(inputSourceID, forKey: .inputSourceID)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}

struct DiagnosticsSnapshot: Equatable, Sendable {
    var accessibilityTrusted = false
    var iCloudPasswordsAutomationStatus = ICloudPasswordsAutomationStatus.disabled.displayText
    var inputSourceSwitchingStatus = InputSourceSwitchingStatus.disabled.displayText
    var logFilePath = ""
    var logText = ""
    var versionLogFilePath = ""
    var versionLogText = ""
    var settingsFilePath = ""
    var registeredHotKeys: [String] = []
    var hotKeyIssues: [String] = []
    var lastExternalApp = "Unknown"
    var gitVersion = GitVersionSnapshot()
    var gitCommitHistory: [String] = []
}

struct GitVersionSnapshot: Equatable, Sendable {
    var isAvailable = false
    var availabilityMessage = ""
    var repositoryPath = ""
    var branch = ""
    var commitHash = ""
    var shortCommitHash = ""
    var isDirty = false
    var dirtyFiles: [String] = []
    var recentCommits: [String] = []
}

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case general = "General"
    case memory = "Memory"
    case clipboardHistory = "Clipboard History"
    case inputSources = "Input Sources"
    case commands = "AI Commands"
    case versionHistory = "Version History"

    var id: String { rawValue }
}

enum AIMemorySource: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case command = "AI Command"
    case chat = "AI Chat"

    var id: String { rawValue }
}

struct AIMemoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var source: AIMemorySource
    var title: String
    var summary: String
    var createdAt: Date
    var updatedAt: Date
    var relatedID: String?

    init(
        id: UUID = UUID(),
        source: AIMemorySource,
        title: String,
        summary: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        relatedID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.relatedID = relatedID
    }
}

enum AppError: LocalizedError {
    case invalidBaseURL
    case emptySelection
    case noActiveApplication
    case hotKeyRequiresModifier
    case accessibilityPermissionMissing
    case clipboardCopyFailed
    case noResponseText
    case appleScriptFailed(String)
    case skillExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "The API base URL is invalid."
        case .emptySelection:
            "No selected text was found in the current app."
        case .noActiveApplication:
            "Could not determine the target application."
        case .hotKeyRequiresModifier:
            "Global shortcuts must include Command, Option, or Control."
        case .accessibilityPermissionMissing:
            "Accessibility permission is required to read and replace selected text."
        case .clipboardCopyFailed:
            "The clipboard fallback did not capture any selected text."
        case .noResponseText:
            "The model response did not contain any text."
        case .appleScriptFailed(let message):
            "Replace failed: \(message)"
        case .skillExecutionFailed(let message):
            message
        }
    }

    var suggestsOpeningAccessibilitySettings: Bool {
        if case .accessibilityPermissionMissing = self {
            return true
        }
        return false
    }
}
