import AppKit

enum WindowPositioning {
    @MainActor
    static func recenterOnPointerScreen(_ window: NSWindow) {
        let targetFrame = targetScreen(for: window)?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let targetFrame else {
            window.center()
            return
        }

        let windowSize = window.frame.size
        let origin = NSPoint(
            x: targetFrame.midX - (windowSize.width / 2),
            y: targetFrame.midY - (windowSize.height / 2)
        )
        window.setFrameOrigin(origin)
    }

    @MainActor
    private static func targetScreen(for window: NSWindow) -> NSScreen? {
        let pointerLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: {
            NSMouseInRect(pointerLocation, $0.frame, false)
        }) {
            return pointerScreen
        }

        return window.screen
    }
}
