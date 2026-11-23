import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct InputSourceSettingsView: View {
    private static let fallbackApplicationIcon: NSImage = NSWorkspace.shared.icon(for: .applicationBundle)

    let appModel: AppModel

    @State private var appMetadataCache: [String: ResolvedAppMetadata] = [:]
    @State private var runningApps: [RunningAppOption] = []

    var body: some View {
        SettingsPageContainer {
            SettingsPageHeader(
                title: "Input Sources",
                subtitle: "Automatically switch keyboard layouts and input methods based on the active app."
            )
            automaticSwitchingSection
            applicationRulesSection
        }
        .onAppear {
            refreshInputSourcesAndApplications()
        }
        .onChange(of: appModel.settings.appInputSourceRules) { _, updatedRules in
            refreshAppMetadataCache(for: updatedRules)
            refreshRunningApps(excludingRules: updatedRules)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshRunningApps(excludingRules: appModel.settings.appInputSourceRules)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshRunningApps(excludingRules: appModel.settings.appInputSourceRules)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await appModel.refreshDiagnostics()
            }
        }
    }

    private var isWarningStatus: Bool {
        if case .warning = appModel.inputSourceSwitchingStatus {
            return true
        }
        return false
    }

    private var automaticSwitchingSection: some View {
        settingsSection(title: "Automatic Switching") {
            settingsGroup {
                VStack(alignment: .leading, spacing: 6) {
                    settingsRow(
                        "Switch by Active App",
                        subtitle: "Uses your default English layout globally—including Spotlight—and switches automatically for apps below. Keep macOS’s “Automatically switch to a document’s input source” off in System Settings → Keyboard."
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { appModel.settings.inputSourceSwitchingEnabled },
                                set: { appModel.setInputSourceSwitchingEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Automatically switch input source by active app")
                    }

                    Text(appModel.inputSourceSwitchingStatus.displayText)
                        .font(.caption)
                        .foregroundStyle(isWarningStatus ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .padding(.bottom, 4)

                    if !appModel.diagnostics.accessibilityTrusted && appModel.settings.inputSourceSwitchingEnabled {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)

                            Text("Grant Accessibility permission to enable automatic switching when opening and closing Spotlight.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Grant Permission") {
                                appModel.promptForAccessibilityPermission()
                            }
                            .buttonStyle(.link)
                            .font(.caption)

                            Button("Open Settings") {
                                appModel.openAccessibilitySettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        .padding(.bottom, 4)
                    }
                }

                Divider()

                settingsRow("Default English Source") {
                    Picker("", selection: defaultEnglishBinding) {
                        Text("Automatic (\(appModel.automaticDefaultEnglishInputSource?.localizedName ?? "English"))")
                            .tag(String?.none)

                        Divider()

                        ForEach(asciiCapableInputSources) { source in
                            Text(source.localizedName)
                                .tag(Optional(source.id))
                        }

                        if let selectedID = appModel.settings.defaultEnglishInputSourceID,
                           !asciiCapableInputSources.contains(where: { $0.id == selectedID }) {
                            Text("\(selectedID) (Unavailable on this Mac)")
                                .tag(Optional(selectedID))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityLabel("Default English input source")
                    .fixedSize()
                }
            }
        }
    }

    private var applicationRulesSection: some View {
        settingsSection(title: "Application Rules") {
            settingsGroup {
                HStack(spacing: 12) {
                    Menu {
                        if !appModel.settings.appInputSourceRules.contains(where: {
                            $0.bundleIdentifier == AppSettings.spotlightBundleIdentifier
                        }) {
                            Button {
                                addSpotlightRule()
                            } label: {
                                Label("Spotlight", systemImage: "magnifyingglass")
                            }

                            Divider()
                        }

                        if runningApps.isEmpty {
                            Text("No other running applications")
                                .disabled(true)
                        } else {
                            ForEach(runningApps) { app in
                                Button(app.localizedName) {
                                    addApplicationRule(
                                        bundleIdentifier: app.bundleIdentifier,
                                        appName: app.localizedName
                                    )
                                }
                            }
                        }

                        Divider()

                        Button("Choose from Applications…") {
                            presentApplicationPicker()
                        }
                    } label: {
                        Label("Add Application", systemImage: "plus")
                    }
                    .fixedSize()

                    Spacer()

                    Button("Refresh Input Sources") {
                        refreshInputSourcesAndApplications()
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 8)

                if appModel.settings.appInputSourceRules.isEmpty {
                    Divider()

                    ContentUnavailableView(
                        "No Application Rules",
                        systemImage: "keyboard",
                        description: Text("Every app defaults to English. Add apps like WeChat, Messages, Slack, or Notes to switch to a specific input method automatically.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(appModel.settings.appInputSourceRules) { rule in
                        Divider()
                        ruleRow(for: rule)
                    }
                }
            }
        }
    }

    private func ruleRow(for rule: AppInputSourceRule) -> some View {
        let metadata = appMetadataCache[rule.bundleIdentifier]
        let displayName = metadata?.displayName
            ?? AppSettings.normalizedOptionalIdentifier(rule.appName)
            ?? rule.bundleIdentifier
        let icon = metadata?.icon ?? Self.fallbackApplicationIcon

        return HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(rule.bundleIdentifier)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !appModel.availableInputSources.contains(where: { $0.id == rule.inputSourceID }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This input source is not currently enabled on this Mac.")
            }

            Picker("", selection: inputSourceBinding(for: rule)) {
                ForEach(appModel.availableInputSources) { source in
                    Text(source.localizedName)
                        .tag(source.id)
                }

                if !appModel.availableInputSources.contains(where: { $0.id == rule.inputSourceID }) {
                    Text("\(rule.inputSourceID) (Unavailable)")
                        .tag(rule.inputSourceID)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Input source for \(displayName)")
            .frame(width: 220)

            Toggle("", isOn: ruleEnabledBinding(for: rule))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable input source rule for \(displayName)")
                .help(rule.isEnabled ? "Rule enabled" : "Rule paused")

            Button(role: .destructive) {
                appModel.removeAppInputSourceRule(bundleIdentifier: rule.bundleIdentifier)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete input source rule for \(displayName)")
            .help("Remove rule")
        }
        .padding(.vertical, 10)
    }

    private var asciiCapableInputSources: [KeyboardInputSource] {
        appModel.availableInputSources.filter(\.isASCIICapable)
    }

    private var defaultEnglishBinding: Binding<String?> {
        Binding(
            get: { appModel.settings.defaultEnglishInputSourceID },
            set: { appModel.setDefaultEnglishInputSourceID($0) }
        )
    }

    private func inputSourceBinding(for rule: AppInputSourceRule) -> Binding<String> {
        Binding(
            get: {
                appModel.settings.appInputSourceRules
                    .first(where: { $0.bundleIdentifier == rule.bundleIdentifier })?
                    .inputSourceID ?? rule.inputSourceID
            },
            set: { newSourceID in
                let currentRule = appModel.settings.appInputSourceRules
                    .first(where: { $0.bundleIdentifier == rule.bundleIdentifier }) ?? rule
                appModel.upsertAppInputSourceRule(
                    bundleIdentifier: currentRule.bundleIdentifier,
                    appName: currentRule.appName,
                    inputSourceID: newSourceID,
                    isEnabled: currentRule.isEnabled
                )
            }
        )
    }

    private func ruleEnabledBinding(for rule: AppInputSourceRule) -> Binding<Bool> {
        Binding(
            get: {
                appModel.settings.appInputSourceRules
                    .first(where: { $0.bundleIdentifier == rule.bundleIdentifier })?
                    .isEnabled ?? rule.isEnabled
            },
            set: { isEnabled in
                appModel.setAppInputSourceRuleEnabled(
                    bundleIdentifier: rule.bundleIdentifier,
                    isEnabled: isEnabled
                )
            }
        )
    }

    private func refreshInputSourcesAndApplications() {
        appModel.refreshAvailableInputSources()
        let rules = appModel.settings.appInputSourceRules
        refreshAppMetadataCache(for: rules)
        refreshRunningApps(excludingRules: rules)
        Task {
            await appModel.refreshDiagnostics()
        }
    }

    private func refreshAppMetadataCache(for rules: [AppInputSourceRule]) {
        var updatedCache = appMetadataCache
        for rule in rules {
            let normalizedFallback = AppSettings.normalizedOptionalIdentifier(rule.appName)
            if let existing = updatedCache[rule.bundleIdentifier],
               existing.resolvedFromBundle || existing.fallbackName == normalizedFallback {
                continue
            }
            updatedCache[rule.bundleIdentifier] = Self.resolveAppMetadata(
                bundleIdentifier: rule.bundleIdentifier,
                fallbackName: normalizedFallback
            )
        }
        appMetadataCache = updatedCache
    }

    private func refreshRunningApps(excludingRules rules: [AppInputSourceRule]) {
        let configuredBundleIDs = Set(rules.map(\.bundleIdentifier))
        let ignoredBundleIDs = AppSettings.systemIgnoredBundleIdentifiers
        var seenBundleIDs: Set<String> = []
        var options: [RunningAppOption] = []

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = AppSettings.normalizedOptionalIdentifier(app.bundleIdentifier),
                  !ignoredBundleIDs.contains(bundleID),
                  !AppSettings.spotlightHostBundleIdentifiers.contains(bundleID),
                  !configuredBundleIDs.contains(bundleID),
                  seenBundleIDs.insert(bundleID).inserted else {
                continue
            }

            let localizedName = AppSettings.normalizedOptionalIdentifier(app.localizedName)
                ?? appMetadataCache[bundleID]?.displayName
                ?? Self.resolveAppMetadata(bundleIdentifier: bundleID, fallbackName: nil).displayName
            options.append(
                RunningAppOption(
                    bundleIdentifier: bundleID,
                    localizedName: localizedName
                )
            )
        }

        options.sort {
            $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
        if runningApps != options {
            runningApps = options
        }
    }

    private static func resolveAppMetadata(
        bundleIdentifier: String,
        fallbackName: String?
    ) -> ResolvedAppMetadata {
        if bundleIdentifier == AppSettings.spotlightBundleIdentifier {
            let spotlightURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: AppSettings.spotlightBundleIdentifier
            ) ?? URL(fileURLWithPath: "/System/Library/CoreServices/Spotlight.app")
            if FileManager.default.fileExists(atPath: spotlightURL.path) {
                return ResolvedAppMetadata(
                    displayName: "Spotlight",
                    icon: NSWorkspace.shared.icon(forFile: spotlightURL.path),
                    fallbackName: fallbackName,
                    resolvedFromBundle: true
                )
            }
            return ResolvedAppMetadata(
                displayName: "Spotlight",
                icon: fallbackApplicationIcon,
                fallbackName: fallbackName,
                resolvedFromBundle: false
            )
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            if let bundle = Bundle(url: appURL),
               let displayName = localizedBundleName(for: bundle) {
                return ResolvedAppMetadata(
                    displayName: displayName,
                    icon: icon,
                    fallbackName: fallbackName,
                    resolvedFromBundle: true
                )
            }
            if let fileName = AppSettings.normalizedOptionalIdentifier(
                appURL.deletingPathExtension().lastPathComponent
            ) {
                return ResolvedAppMetadata(
                    displayName: fileName,
                    icon: icon,
                    fallbackName: fallbackName,
                    resolvedFromBundle: true
                )
            }
        }
        return ResolvedAppMetadata(
            displayName: fallbackName ?? bundleIdentifier,
            icon: fallbackApplicationIcon,
            fallbackName: fallbackName,
            resolvedFromBundle: false
        )
    }

    private static func localizedBundleName(for bundle: Bundle) -> String? {
        if let localizedDisplayName = AppSettings.normalizedOptionalIdentifier(
            bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        ) {
            return localizedDisplayName
        }
        if let localizedName = AppSettings.normalizedOptionalIdentifier(
            bundle.localizedInfoDictionary?["CFBundleName"] as? String
        ) {
            return localizedName
        }
        if let displayName = AppSettings.normalizedOptionalIdentifier(
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ) {
            return displayName
        }
        return AppSettings.normalizedOptionalIdentifier(
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        )
    }

    private func addSpotlightRule() {
        appMetadataCache[AppSettings.spotlightBundleIdentifier] = Self.resolveAppMetadata(
            bundleIdentifier: AppSettings.spotlightBundleIdentifier,
            fallbackName: "Spotlight"
        )
        addApplicationRule(
            bundleIdentifier: AppSettings.spotlightBundleIdentifier,
            appName: "Spotlight"
        )
    }

    private func addApplicationRule(bundleIdentifier: String, appName: String) {
        if let existingRule = appModel.settings.appInputSourceRules.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            appModel.upsertAppInputSourceRule(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                inputSourceID: existingRule.inputSourceID,
                isEnabled: true
            )
            return
        }

        guard let preferredSourceID = appModel.preferredNonEnglishInputSourceID() else {
            return
        }

        appModel.upsertAppInputSourceRule(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            inputSourceID: preferredSourceID,
            isEnabled: true
        )
    }

    @MainActor
    private func presentApplicationPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add Application"
        panel.message = "Choose an application to configure its input source."

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                Task { @MainActor in
                    handlePickedApplication(response: response, url: panel.url)
                }
            }
        } else {
            panel.begin { response in
                Task { @MainActor in
                    handlePickedApplication(response: response, url: panel.url)
                }
            }
        }
    }

    @MainActor
    private func handlePickedApplication(response: NSApplication.ModalResponse, url: URL?) {
        guard response == .OK,
              let url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = AppSettings.normalizedOptionalIdentifier(bundle.bundleIdentifier),
              !AppSettings.systemIgnoredBundleIdentifiers.contains(bundleIdentifier) else {
            return
        }

        if AppSettings.spotlightHostBundleIdentifiers.contains(bundleIdentifier) {
            addSpotlightRule()
            return
        }

        let appName = Self.localizedBundleName(for: bundle)
            ?? AppSettings.normalizedOptionalIdentifier(url.deletingPathExtension().lastPathComponent)
            ?? bundleIdentifier
        appMetadataCache[bundleIdentifier] = ResolvedAppMetadata(
            displayName: appName,
            icon: NSWorkspace.shared.icon(forFile: url.path),
            fallbackName: appName,
            resolvedFromBundle: true
        )
        addApplicationRule(bundleIdentifier: bundleIdentifier, appName: appName)
    }
}

private struct ResolvedAppMetadata {
    let displayName: String
    let icon: NSImage
    let fallbackName: String?
    let resolvedFromBundle: Bool
}

private struct RunningAppOption: Identifiable, Equatable {
    let bundleIdentifier: String
    let localizedName: String
    var id: String { bundleIdentifier }
}
