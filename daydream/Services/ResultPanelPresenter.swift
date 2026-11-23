import AppKit
import Observation
import SwiftUI

@MainActor
final class ResultPanelPresenter {
    private let preferredWidth: CGFloat = 640
    private let minHeight: CGFloat = 220
    private let maxHeight: CGFloat = 640
    private var panel: ResultPanel?
    private var hostingController: NSHostingController<ResultPopupView>?
    private var state: ResultPopupState?
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
    }

    func show(
        result: CommandExecutionResult,
        onApply: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        let state = ResultPopupState(result: result)
        self.state = state
        show(
            state: state,
            onApply: onApply,
            onClose: onClose
        )
    }

    func show(
        state: ResultPopupState,
        takeFocus: Bool = true,
        onApply: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        let contentView = ResultPopupView(
            state: state,
            onApply: { [weak self] in
                guard state.canApply else { return }
                self?.close(reason: "apply")
                onApply()
            },
            onClose: { [weak self] in
                self?.close(reason: "close_button")
                onClose()
            }
        )

        let controller = NSHostingController(rootView: contentView)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController = controller

        if panel == nil {
            let newPanel = ResultPanel(
                contentRect: NSRect(x: 0, y: 0, width: preferredWidth, height: 420),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.level = .statusBar
            newPanel.isFloatingPanel = true
            newPanel.hidesOnDeactivate = false
            newPanel.isReleasedWhenClosed = false
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.titlebarAppearsTransparent = true
            newPanel.isMovableByWindowBackground = true
            newPanel.onSystemClose = { [weak self] in
                DispatchQueue.main.async {
                    self?.close(reason: "window_close")
                }
            }
            newPanel.standardWindowButton(.zoomButton)?.isHidden = true
            newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            newPanel.title = state.result.commandTitle

            newPanel.contentView = makeGlassContainer(for: newPanel)
            panel = newPanel
        }

        panel?.onEscape = { [weak self] in
            self?.close(reason: "escape")
            onClose()
        }
        panel?.onApply = { [weak self] in
            guard state.canApply else { return }
            self?.close(reason: "keyboard_apply")
            onApply()
        }

        if #available(macOS 26, *),
           let glassView = panel?.contentView as? NSGlassEffectView {
            glassView.contentView = controller.view
        } else if let effectView = panel?.contentView as? NSVisualEffectView {
            effectView.subviews.forEach { $0.removeFromSuperview() }
            effectView.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: effectView.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            ])
        } else {
            panel?.contentViewController = controller
        }
        panel?.title = state.result.commandTitle
        resizePanelToFitContent(controller: controller)
        guard let panel else { return }

        WindowPositioning.recenterOnPointerScreen(panel)

        // `orderFrontRegardless()` is required when a global shortcut is used
        // from another application's full-screen Space. Calling an ordering
        // API again from the same presentation cycle can make AppKit notify
        // hosted remote views twice while they are still attaching. On newer
        // macOS versions that can raise NSInternalInconsistencyException from ViewBridge.
        panel.orderFrontRegardless()
        if takeFocus { panel.makeKey() }
    }

    func focusIfVisible(resultID: UUID) {
        guard state?.result.id == resultID else { return }
        panel?.makeKey()
    }

    func close(reason: String = "programmatic", resultID: UUID? = nil) {
        if let resultID, state?.result.id != resultID { return }
        guard let panel else { return }

        panel.onEscape = nil
        panel.onApply = nil
        panel.onSystemClose = nil
        panel.orderOut(nil)

        // Stop new callbacks from finding the closing panel immediately, but
        // keep its hosting hierarchy alive until AppKit finishes the current
        // window event. Tearing it down synchronously can invalidate a remote
        // text service while ViewBridge is still processing visibility.
        let closingController = hostingController
        self.panel = nil
        hostingController = nil
        state = nil

        DispatchQueue.main.async { [logger] in
            closingController?.view.removeFromSuperview()
            panel.contentViewController = nil
            panel.close()

            Task {
                await logger.log(
                    "window",
                    "Released result panel resources",
                    metadata: [
                        "reason": reason,
                        "retained_windows": "\(NSApp.windows.count)",
                        "visible_windows": "\(NSApp.windows.filter(\.isVisible).count)",
                    ]
                )
            }
        }
    }

    private func resizePanelToFitContent(controller: NSHostingController<ResultPopupView>) {
        controller.view.frame = NSRect(x: 0, y: 0, width: preferredWidth, height: 10)
        controller.view.layoutSubtreeIfNeeded()

        let fittingSize = controller.view.fittingSize
        let resolvedHeight = max(minHeight, min(maxHeight, fittingSize.height))
        panel?.setContentSize(NSSize(width: preferredWidth, height: resolvedHeight))
        panel?.minSize = NSSize(width: 520, height: minHeight)
        panel?.maxSize = NSSize(width: preferredWidth, height: maxHeight)
    }

    private func makeGlassContainer(for panel: NSPanel) -> NSView {
        let frame = panel.contentRect(forFrameRect: panel.frame)

        if #available(macOS 26, *) {
            let glassView = NSGlassEffectView(frame: frame)
            glassView.autoresizingMask = [.width, .height]
            glassView.cornerRadius = 0
            glassView.style = .regular
            return glassView
        }

        let effectView = NSVisualEffectView(frame: frame)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        return effectView
    }
}

private final class ResultPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onApply: (() -> Void)?
    var onSystemClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        onSystemClose?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onEscape?()
        case 36, 76:
            onApply?()
        default:
            super.keyDown(with: event)
        }
    }
}
