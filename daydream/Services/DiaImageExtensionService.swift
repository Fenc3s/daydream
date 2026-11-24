import AppKit
import Foundation

@MainActor
final class DiaImageExtensionService {
    static let shared = DiaImageExtensionService()

    static let extensionID = "elclpipnfhkjpcfkefflijpdieaelobd"
    static let nativeHostName = "com.daydream.app"

    private let fileManager = FileManager.default

    var isNativeMessagingLaunch: Bool {
        CommandLine.arguments.dropFirst().contains {
            $0 == "chrome-extension://\(Self.extensionID)/"
        }
    }

    func registerNativeMessagingHost() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw DiaImageExtensionError.missingExecutable
        }

        let manifest: [String: Any] = [
            "name": Self.nativeHostName,
            "description": "Save browser images to Photos through Daydream",
            "path": executableURL.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let diaSupportDirectory = applicationSupportDirectory
            .appendingPathComponent("Dia", isDirectory: true)
        let manifestDirectories = [
            diaSupportDirectory.appendingPathComponent("NativeMessagingHosts", isDirectory: true),
            diaSupportDirectory
                .appendingPathComponent("User Data", isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true),
            applicationSupportDirectory
                .appendingPathComponent("Google", isDirectory: true)
                .appendingPathComponent("Chrome", isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true),
            applicationSupportDirectory
                .appendingPathComponent("Chromium", isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true),
        ]

        for manifestDirectory in manifestDirectories {
            try fileManager.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
            let manifestURL = manifestDirectory.appendingPathComponent("\(Self.nativeHostName).json")
            if (try? Data(contentsOf: manifestURL)) == data {
                continue
            }
            try data.write(to: manifestURL, options: .atomic)
        }
    }

    func openExtensionInstaller() {
        guard let extensionURL = Bundle.main.resourceURL?.appendingPathComponent("DiaSaveImageExtension", isDirectory: true),
              fileManager.fileExists(atPath: extensionURL.appendingPathComponent("manifest.json").path) else {
            presentAlert(
                title: "Save Image Extension Not Found",
                message: "Reinstall Daydream, then try again."
            )
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([extensionURL])

        guard let extensionsPageURL = URL(string: "chrome://extensions") else {
            return
        }

        let browserURLs = ["company.thebrowser.dia", "com.google.Chrome"].compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        guard !browserURLs.isEmpty else {
            presentAlert(
                title: "Supported Browser Not Found",
                message: "Install Dia or Google Chrome, then try again."
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        for browserURL in browserURLs {
            NSWorkspace.shared.open(
                [extensionsPageURL],
                withApplicationAt: browserURL,
                configuration: configuration
            )
        }
    }

    func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private enum DiaImageExtensionError: LocalizedError {
    case missingExecutable

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "Daydream could not locate its native messaging executable."
        }
    }
}
