import SwiftUI

struct DiagnosticsWindowView: View {
    let appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Text("Diagnostics")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Spacer()
                    Button("Refresh") {
                        Task {
                            await appModel.refreshDiagnostics()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                diagnosticCard(title: "Runtime Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow(label: "Accessibility", value: appModel.diagnostics.accessibilityTrusted ? "Granted" : "Missing")
                        statusRow(label: "iCloud Passwords for Browsers", value: appModel.diagnostics.iCloudPasswordsAutomationStatus)
                        statusRow(label: "Input Source Switching", value: appModel.diagnostics.inputSourceSwitchingStatus)
                        statusRow(label: "Last Target App", value: appModel.diagnostics.lastExternalApp)
                        statusRow(label: "Settings File", value: appModel.diagnostics.settingsFilePath)
                        statusRow(label: "iCloud Sync", value: appModel.diagnostics.iCloudSyncAvailable ? "Available" : "Unavailable")
                        if !appModel.diagnostics.iCloudSyncDirectoryPath.isEmpty {
                            statusRow(label: "iCloud Directory", value: appModel.diagnostics.iCloudSyncDirectoryPath)
                        }
                        statusRow(label: "Log File", value: appModel.diagnostics.logFilePath)
                        statusRow(label: "Version Log", value: appModel.diagnostics.versionLogFilePath)
                    }
                }

                diagnosticCard(title: "Git Version") {
                    VStack(alignment: .leading, spacing: 12) {
                        if appModel.diagnostics.gitVersion.isAvailable {
                            statusRow(label: "Repository", value: appModel.diagnostics.gitVersion.repositoryPath)
                            statusRow(label: "Branch", value: appModel.diagnostics.gitVersion.branch)
                            statusRow(label: "Commit", value: "\(appModel.diagnostics.gitVersion.shortCommitHash)  (\(appModel.diagnostics.gitVersion.commitHash))")
                            statusRow(
                                label: "Working Tree",
                                value: appModel.diagnostics.gitVersion.isDirty
                                    ? "Dirty (\(appModel.diagnostics.gitVersion.dirtyFiles.count) changed files)"
                                    : "Clean"
                            )

                            if !appModel.diagnostics.gitVersion.dirtyFiles.isEmpty {
                                Divider()
                                Text("Dirty Files")
                                    .font(.headline)
                                ForEach(appModel.diagnostics.gitVersion.dirtyFiles, id: \.self) { item in
                                    Text(item)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }

                            if !appModel.diagnostics.gitVersion.recentCommits.isEmpty {
                                Divider()
                                Text("Recent Commits")
                                    .font(.headline)
                                ForEach(appModel.diagnostics.gitVersion.recentCommits, id: \.self) { item in
                                    Text(item)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        } else {
                            Text(appModel.diagnostics.gitVersion.availabilityMessage.isEmpty ? "Git metadata is unavailable." : appModel.diagnostics.gitVersion.availabilityMessage)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                diagnosticCard(title: "Hot Keys") {
                    VStack(alignment: .leading, spacing: 12) {
                        if appModel.diagnostics.registeredHotKeys.isEmpty {
                            Text("No shortcuts registered.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(appModel.diagnostics.registeredHotKeys, id: \.self) { item in
                                Text(item)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }

                        if !appModel.diagnostics.hotKeyIssues.isEmpty {
                            Divider()
                            ForEach(appModel.diagnostics.hotKeyIssues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                }

                diagnosticCard(title: "Actions") {
                    HStack(spacing: 12) {
                        Button("Request Accessibility Access") {
                            appModel.promptForAccessibilityPermission()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open Accessibility Settings") {
                            appModel.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)

                        Button("Reveal Log File") {
                            appModel.revealLogFile()
                        }
                        .buttonStyle(.bordered)

                        Button("Reveal Version Log") {
                            appModel.revealVersionLogFile()
                        }
                        .buttonStyle(.bordered)

                        Button("Reveal Repository") {
                            appModel.revealRepository()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                diagnosticCard(title: "Recent Log") {
                    ScrollView(.horizontal) {
                        Text(appModel.diagnostics.logText.isEmpty ? "No logs yet." : appModel.diagnostics.logText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(Color.black.opacity(0.82))
                            )
                            .foregroundStyle(.white)
                    }
                    .frame(minHeight: 320)
                }

                diagnosticCard(title: "Version Log") {
                    ScrollView(.horizontal) {
                        Text(appModel.diagnostics.versionLogText.isEmpty ? "No version markers yet." : appModel.diagnostics.versionLogText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(Color.black.opacity(0.82))
                            )
                            .foregroundStyle(.white)
                    }
                    .frame(minHeight: 220)
                }
            }
            .padding(28)
        }
        .task {
            await appModel.refreshDiagnostics()
        }
        .onAppear {
            appModel.updateWindowLifecycle(named: "Diagnostics", isVisible: true)
        }
        .onDisappear {
            appModel.updateWindowLifecycle(named: "Diagnostics", isVisible: false)
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .fontWeight(.semibold)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private func diagnosticCard<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 18) {
        Text(title)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
        content()
    }
    .padding(24)
    .background(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(.ultraThinMaterial)
    )
}
