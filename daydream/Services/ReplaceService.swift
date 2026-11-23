import AppKit
import Carbon
import Foundation

final class ReplaceService {
    private let targetActivationDelay = Duration.milliseconds(180)
    private let logger: AppLogger

    init(logger: AppLogger) {
        self.logger = logger
    }

    func replaceSelectedText(
        with replacement: String,
        in target: ExternalApplicationTarget,
        restoreAnchor: SelectionRestoreAnchor? = nil
    ) async throws {
        let pasteboard = NSPasteboard.general

        guard let runningApp = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            throw AppError.noActiveApplication
        }

        do {
            runningApp.activate(options: [.activateAllWindows])
            try await Task.sleep(for: targetActivationDelay)
            let restoreStatus = restoreSelectionIfPossible(restoreAnchor)

            // Write only .string to the pasteboard — no RTF, no HTML. This guarantees
            // the paste is plain text in every app, so we can use the universal Cmd+V
            // without needing app-specific "Paste and Match Style" (Cmd+Option+Shift+V).
            // "Paste and Match Style" is only meaningful when the clipboard contains
            // rich-text types that need to be stripped; since we never write those,
            // Cmd+V produces identical plain-text output across all apps.
            writeReplacement(replacement, to: pasteboard)
            try executePaste(target: target)
            await logger.log(
                "replace",
                "Replaced selected text",
                metadata: [
                    "app": target.displayName,
                    "bundle_id": target.bundleIdentifier ?? "nil",
                    "length": "\(replacement.count)",
                    "selection_restore": restoreStatus,
                ]
            )
        }
    }

    func pasteCurrentClipboard(into target: ExternalApplicationTarget) async throws {
        guard let runningApp = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            throw AppError.noActiveApplication
        }

        runningApp.activate(options: [.activateAllWindows])
        try await Task.sleep(for: targetActivationDelay)

        try executePaste(target: target)
        await logger.log(
            "replace",
            "Pasted current clipboard into selection",
            metadata: [
                "app": target.displayName,
            ]
        )
    }

    // MARK: - Private

    private func executePaste(target: ExternalApplicationTarget) throws {
        do {
            try postPasteEvents(to: target.processIdentifier)
        } catch {
            try executePasteScript(target: target)
        }
    }

    private func restoreSelectionIfPossible(_ anchor: SelectionRestoreAnchor?) -> String {
        guard let anchor else { return "no_anchor" }

        let focusResult = AXUIElementSetAttributeValue(
            anchor.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )

        var range = CFRange(location: anchor.selectedRange.location, length: anchor.selectedRange.length)
        guard let axRange = AXValueCreate(.cfRange, &range) else {
            return "range_create_failed,focus=\(focusResult.rawValue)"
        }

        let rangeResult = AXUIElementSetAttributeValue(
            anchor.element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        )

        return "focus=\(focusResult.rawValue),range=\(rangeResult.rawValue)"
    }

    private func postPasteEvents(to processIdentifier: pid_t) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              ) else {
            throw AppError.appleScriptFailed("Failed to create keyboard events for paste.")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }

    private func executePasteScript(target: ExternalApplicationTarget) throws {
        let activationScript: String
        if let bundleIdentifier = target.bundleIdentifier {
            activationScript = "tell application id \"\(escaped(bundleIdentifier))\" to activate"
        } else {
            activationScript = ""
        }

        let script = """
        \(activationScript)
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            throw AppError.appleScriptFailed(errorInfo.description)
        }
    }

    private func writeReplacement(_ replacement: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
