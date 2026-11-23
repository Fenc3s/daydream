import AppKit
import SwiftUI

/// Presents the Clipboard History UI in an NSPanel that can appear on top of
/// full-screen spaces. Unlike a standard SwiftUI Window scene, this panel uses
/// `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so macOS
/// will render it in whichever Space (including a full-screen app's Space) is
/// currently active when the hot-key fires.
@MainActor
final class ClipboardHistoryPanelPresenter {
    private var panel: ClipboardHistoryPanel?
    private weak var appModel: AppModel?
    private let logger: AppLogger

    init(appModel: AppModel, logger: AppLogger) {
        self.appModel = appModel
        self.logger = logger
    }

    // MARK: - Public

    func show() {
        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }
        WindowPositioning.recenterOnPointerScreen(panel)

        // `orderFrontRegardless()` is the critical call for a global hotkey
        // panel: it surfaces the window even when another app owns the active
        // Space. Do not activate daydream here; activating a menu-bar app from
        // a full-screen Space makes macOS switch back to daydream's desktop.
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            WindowPositioning.recenterOnPointerScreen(panel)
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close(reason: String = "dismiss") {
        guard let panel else { return }

        panel.onSystemClose = nil
        panel.onNavigationLog = nil
        panel.orderOut(nil)
        panel.contentViewController = nil
        panel.close()
        self.panel = nil

        Task {
            await logger.log(
                "window",
                "Released clipboard history panel resources",
                metadata: [
                    "reason": reason,
                    "retained_windows": "\(NSApp.windows.count)",
                    "visible_windows": "\(NSApp.windows.filter(\.isVisible).count)",
                ]
            )
        }
    }

    // MARK: - Private

    private func makePanel() -> ClipboardHistoryPanel {
        guard let appModel else {
            fatalError("ClipboardHistoryPanelPresenter: appModel was deallocated before panel creation")
        }

        let contentView = ClipboardHistoryWindowView(appModel: appModel) {
            // onDismiss callback — close the panel instead of using dismissWindow.
            [weak self] in self?.close(reason: "dismiss")
        }

        let controller = NSHostingController(rootView: contentView)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        // Prevent the hosting controller from resizing the panel whenever
        // SwiftUI reports a different ideal size (e.g. after search filters
        // reduce the number of list items).
        controller.sizingOptions = []

        let newPanel = ClipboardHistoryPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ClipboardHistoryLayout.windowSize.width,
                height: ClipboardHistoryLayout.windowSize.height
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // `canJoinAllSpaces`    → panel appears in every Space including
        //                         full-screen app Spaces.
        // `fullScreenAuxiliary` → panel stays visible when another app goes
        //                         full-screen.
        // Note: `.managed` is intentionally omitted — it lets the system assign
        // the panel to a specific Space/desktop, which conflicts with the
        // "show everywhere" intent of the two flags above.
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        newPanel.level = .statusBar
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.titlebarAppearsTransparent = true
        newPanel.title = "Clipboard History"
        newPanel.onNavigationLog = { [logger] message, metadata in
            Task {
                await logger.log("clipboard-navigation", message, metadata: metadata)
            }
        }
        newPanel.onSystemClose = { [weak self] in
            DispatchQueue.main.async {
                self?.close(reason: "window_close")
            }
        }
        newPanel.minSize = ClipboardHistoryLayout.windowSize
        newPanel.setContentSize(ClipboardHistoryLayout.windowSize)

        newPanel.contentView = makeGlassContainer(
            for: newPanel,
            contentView: controller.view
        )
        WindowPositioning.recenterOnPointerScreen(newPanel)

        return newPanel
    }

    private func makeGlassContainer(for panel: NSPanel, contentView: NSView) -> NSView {
        let frame = NSRect(origin: .zero, size: ClipboardHistoryLayout.windowSize)

        if #available(macOS 26, *) {
            let glassView = NSGlassEffectView(frame: frame)
            glassView.autoresizingMask = [.width, .height]
            glassView.cornerRadius = 0
            glassView.style = .regular

            let containerView = NSView(frame: frame)
            containerView.autoresizingMask = [.width, .height]
            containerView.translatesAutoresizingMaskIntoConstraints = true

            containerView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: containerView.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])

            glassView.contentView = containerView
            return glassView
        }

        let effectView = NSVisualEffectView(frame: frame)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]

        effectView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        return effectView
    }
}

// MARK: - ClipboardHistoryPanel

/// A custom NSPanel subclass that explicitly allows becoming the key window.
/// The default NSPanel implementation may refuse `canBecomeKey` in some
/// configurations; overriding it ensures keyboard input (search field, etc.)
/// works correctly even when daydream is not the frontmost application.
private final class ClipboardHistoryPanel: NSPanel {
    var onSystemClose: (() -> Void)?
    var onNavigationLog: ((String, [String: String]) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        onSystemClose?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, Self.isArrowKeyEvent(event) {
            onNavigationLog?(
                "Clipboard history panel sendEvent received arrow key",
                eventMetadata(event)
            )
        }

        if event.type == .keyDown, handleMoveSelectionKey(event) {
            return
        }

        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isArrowKeyEvent(event) {
            onNavigationLog?(
                "Clipboard history panel keyDown received arrow key",
                eventMetadata(event)
            )
        }

        if handleMoveSelectionKey(event) {
            return
        }

        super.keyDown(with: event)
    }

    private func handleMoveSelectionKey(_ event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard modifierFlags.isEmpty else {
            if Self.isArrowKeyEvent(event) {
                onNavigationLog?(
                    "Clipboard history arrow key ignored because modifiers are active",
                    eventMetadata(event).merging(["effective_modifiers": "\(modifierFlags.rawValue)"]) { _, new in new }
                )
            }
            return false
        }

        switch event.keyCode {
        case 126:
            onNavigationLog?(
                "Posting clipboard history move notification",
                eventMetadata(event).merging(["direction": "up"]) { _, new in new }
            )
            NotificationCenter.default.post(
                name: .clipboardHistoryMoveSelection,
                object: self,
                userInfo: ["direction": "up"]
            )
            return true
        case 125:
            onNavigationLog?(
                "Posting clipboard history move notification",
                eventMetadata(event).merging(["direction": "down"]) { _, new in new }
            )
            NotificationCenter.default.post(
                name: .clipboardHistoryMoveSelection,
                object: self,
                userInfo: ["direction": "down"]
            )
            return true
        default:
            return false
        }
    }

    private static func isArrowKeyEvent(_ event: NSEvent) -> Bool {
        event.keyCode == 126 || event.keyCode == 125
    }

    private func eventMetadata(_ event: NSEvent) -> [String: String] {
        [
            "key_code": "\(event.keyCode)",
            "characters": event.charactersIgnoringModifiers ?? "nil",
            "modifiers": "\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)",
            "is_key_window": "\(isKeyWindow)",
            "first_responder": "\(String(describing: firstResponder))",
            "window_title": title,
        ]
    }
}
