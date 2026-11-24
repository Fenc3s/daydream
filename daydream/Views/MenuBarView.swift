import AppKit
import Carbon
import SwiftUI

struct MenuBarView: View {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("daydream \(appModel.applicationVersionDisplay)")
            .foregroundStyle(.secondary)
            .onAppear {
                appModel.refreshAccessibilityTrustState()
            }

        Divider()

        Group {
            if appModel.diagnostics.accessibilityTrusted {
                permissionStatusLabel(
                    text: "Accessibility Granted",
                    color: .green
                )
            } else {
                Button {
                    appModel.promptForAccessibilityPermission()
                } label: {
                    permissionStatusLabel(
                        text: "Grant Accessibility Permission",
                        color: .red
                    )
                }
            }

            if appModel.isExecuting {
                Text("Running \(appModel.executingCommandTitle ?? "command")…")
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        Menu("Provider: \(appModel.settings.provider.displayName)") {
            ForEach(AIProvider.allCases) { provider in
                Button {
                    appModel.selectProvider(provider)
                } label: {
                    if provider == appModel.settings.provider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        }

        Menu("Model: \(appModel.settings.defaultModel)") {
            ForEach(availableModels, id: \.self) { model in
                Button {
                    selectModel(model)
                } label: {
                    if model == appModel.settings.defaultModel {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        }

        Menu("Reasoning: \(appModel.defaultReasoningMode(for: appModel.settings.defaultModel).displayName)") {
            ForEach(appModel.availableReasoningModes(for: appModel.settings.defaultModel)) { mode in
                Button {
                    appModel.selectDefaultReasoning(mode)
                } label: {
                    if mode == appModel.defaultReasoningMode(for: appModel.settings.defaultModel) {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        }

        Divider()

        Menu("AI Commands") {
            ForEach(appModel.settings.commands) { command in
                Button(commandMenuTitle(for: command)) {
                    appModel.runCommand(command, trigger: "menu")
                }
                .disabled(appModel.isExecuting)
                .applyMenuShortcut(command.shortcut)

                if appModel.executingCommandID == command.id {
                    Text("Running…")
                        .foregroundStyle(.secondary)
                } else if appModel.hotKeyConflicts.contains(command.id), let shortcut = command.shortcut {
                    Text("Global shortcut conflict: \(shortcut.displayString)")
                        .foregroundStyle(.secondary)
                }
            }
        }

        Button(clipboardHistoryMenuTitle) {
            appModel.requestOpenClipboardHistoryWindow()
        }
        .applyMenuShortcut(appModel.settings.clipboardHistoryShortcut)

        Button("Save Clipboard Image to Photos") {
            appModel.saveClipboardImageToPhotos()
        }

        Button("Install Save Image Extension…") {
            appModel.openSaveImageExtensionInstaller()
        }

        Menu("Input Sources: \(appModel.settings.inputSourceSwitchingEnabled ? "Auto" : "Off")") {
            Button {
                appModel.setInputSourceSwitchingEnabled(!appModel.settings.inputSourceSwitchingEnabled)
            } label: {
                if appModel.settings.inputSourceSwitchingEnabled {
                    Label("Auto-Switch Input Sources", systemImage: "checkmark")
                } else {
                    Text("Auto-Switch Input Sources")
                }
            }

            Divider()

            Button("Configure App Rules…") {
                presentSettings(section: .inputSources)
            }
        }

        Button("Settings…") {
            presentSettings()
        }

        Button("Show Diagnostics") {
            Task {
                await appModel.refreshDiagnostics()
                appModel.prepareForAppWindowPresentation()
                openWindow(id: AppModel.diagnosticsWindowID)
                try? await Task.sleep(for: .milliseconds(120))
                appModel.finalizeWindowPresentation(matchingTitle: "diagnostics")
            }
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func presentSettings(section: SettingsSection? = nil) {
        if let section {
            appModel.selectedSettingsSection = section
        }
        appModel.prepareForAppWindowPresentation()
        openSettings()
        Task { @MainActor in
            appModel.finalizeSettingsWindowPresentation()
            try? await Task.sleep(for: .milliseconds(120))
            appModel.finalizeSettingsWindowPresentation()
        }
    }

    private func commandMenuTitle(for command: AICommand) -> String {
        if appModel.hotKeyConflicts.contains(command.id) {
            return "\(command.title)  \u{26A0}\u{FE0F}"
        }
        return command.title
    }

    private var clipboardHistoryMenuTitle: String {
        if appModel.hotKeyConflicts.contains(AppModel.clipboardHistoryShortcutID),
           appModel.settings.clipboardHistoryShortcut != nil {
            return "Clipboard History  ⚠️"
        }
        return "Clipboard History"
    }

    private var availableModels: [String] {
        let catalog = appModel.settings.modelCatalog(for: appModel.settings.provider)
        if catalog.contains(appModel.settings.defaultModel) {
            return catalog
        }
        return [appModel.settings.defaultModel] + catalog
    }

    private func selectModel(_ model: String) {
        guard model != appModel.settings.defaultModel else { return }
        appModel.settings.setDefaultModel(model, for: appModel.settings.provider)
        appModel.saveSettings()
    }

    @ViewBuilder
    private func permissionStatusLabel(text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
        }
    }
}

private struct MenuShortcutModifier: ViewModifier {
    let shortcut: KeyboardShortcut?

    func body(content: Content) -> some View {
        guard let shortcut,
              let keyEquivalent = shortcut.keyEquivalent,
              let modifiers = shortcut.eventModifiers else {
            return AnyView(content)
        }

        return AnyView(content.keyboardShortcut(keyEquivalent, modifiers: modifiers))
    }
}

private extension View {
    func applyMenuShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        modifier(MenuShortcutModifier(shortcut: shortcut))
    }
}

private extension KeyboardShortcut {
    var keyEquivalent: KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_Space: return .space
        case kVK_Return: return .return
        case kVK_Tab: return .tab
        default:
            guard let key = Self.keyLabel(for: keyCode)?.lowercased(),
                  key.count == 1,
                  let scalar = key.unicodeScalars.first else {
                return nil
            }
            return KeyEquivalent(Character(scalar))
        }
    }

    var eventModifiers: SwiftUI.EventModifiers? {
        var value: SwiftUI.EventModifiers = []
        if modifiers.contains(.command) {
            value.insert(.command)
        }
        if modifiers.contains(.option) {
            value.insert(.option)
        }
        if modifiers.contains(.control) {
            value.insert(.control)
        }
        if modifiers.contains(.shift) {
            value.insert(.shift)
        }
        return value.isEmpty ? nil : value
    }
}

struct MenuBarLabelView: View {
    let appModel: AppModel
    @State private var animateStrength = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appModel.isExecuting {
                Text("💪")
                    .font(.system(size: 15))
                    .scaleEffect(animateStrength ? 1.08 : 0.9)
                    .rotationEffect(.degrees(animateStrength ? -8 : 8))
                    .animation(.easeInOut(duration: 0.48).repeatForever(autoreverses: true), value: animateStrength)
            } else {
                Image(systemName: "figure.martial.arts")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .onAppear {
            animateStrength = appModel.isExecuting
        }
        .onChange(of: appModel.isExecuting) { _, isExecuting in
            animateStrength = isExecuting
        }
        .onChange(of: appModel.clipboardHistoryOpenRequestToken) { _, _ in
            // The panel is now shown directly from AppModel.requestOpenClipboardHistoryWindow().
            // This onChange remains as a no-op hook so the token stays observable
            // if additional UI reactions are needed in the future.
        }
        .accessibilityLabel("daydream")
    }
}
