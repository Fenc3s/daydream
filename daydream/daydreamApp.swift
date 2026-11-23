import SwiftUI

@main
struct daydreamApp: App {
    // Using NSApplicationDelegateAdaptor to integrate with the AppKit app life cycle.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // The main model for the application, stored as state.
    @State private var appModel = AppModel()

    var body: some Scene {
        // The main menu bar extra for the application.
        MenuBarExtra {
            MenuBarView(appModel: appModel)
        } label: {
            MenuBarLabelView(appModel: appModel)
        }
        .menuBarExtraStyle(.menu)

        // The native settings scene manages its own singleton window lifecycle.
        Settings {
            SettingsRootView(appModel: appModel)
                .frame(minWidth: 980, minHeight: 680)
        }

        // The diagnostics window for the application.
        Window("Diagnostics", id: AppModel.diagnosticsWindowID) {
            DiagnosticsWindowView(appModel: appModel)
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowToolbarStyle(.unifiedCompact)


    }
}

// The AppDelegate for the application, handling app life cycle events.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let photoLibraryService = PhotoLibraryService.shared
    private let diaImageExtensionService = DiaImageExtensionService.shared

    // Set the activation policy to .accessory so the app doesn't appear in the Dock.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let logger = AppLogger.shared
        photoLibraryService.configure(logger: logger)

        if diaImageExtensionService.isNativeMessagingLaunch {
            Task {
                await NativeMessagingHost.run(photoLibraryService: photoLibraryService, logger: logger)
                NSApp.terminate(nil)
            }
            return
        }

        do {
            try diaImageExtensionService.registerNativeMessagingHost()
        } catch {
            Task {
                await logger.log(
                    "photos",
                    "Failed to register Dia native messaging host",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    // Prevent the app from terminating when the last window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}
