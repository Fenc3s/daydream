import AppKit
import ApplicationServices
import Carbon
import Foundation

final class SelectionService {
    private let logger: AppLogger
    private let fallbackAttempts = 3
    private let frontmostActivationPollCount = 12
    private let frontmostActivationPollInterval = Duration.milliseconds(80)

    init(logger: AppLogger) {
        self.logger = logger
    }

    func captureSelection(for target: ExternalApplicationTarget) async throws -> CapturedSelection {
        await logger.log(
            "selection",
            "Starting selection capture",
            metadata: [
                "app": target.displayName,
                "bundle_id": target.bundleIdentifier ?? "nil",
                "pid": "\(target.processIdentifier)",
                "ax_trusted": "\(isAccessibilityTrusted())",
                "frontmost_app": frontmostAppDescription(),
            ]
        )

        let probe = probeSelectedTextFromAccessibility(processIdentifier: target.processIdentifier)
        if let selectedText = probe.text {
            await logger.log(
                "selection",
                "AX selected text succeeded",
                metadata: [
                    "app": target.displayName,
                    "method": SelectionCaptureSource.accessibility.rawValue,
                    "length": "\(selectedText.count)",
                    "details": probe.details,
                ]
            )
            return CapturedSelection(text: selectedText, source: .accessibility, target: target, restoreAnchor: probe.restoreAnchor)
        }

        await logger.log(
            "selection",
            "AX selected text failed, using clipboard fallback",
            metadata: [
                "app": target.displayName,
                "details": probe.details,
            ]
        )

        let fallbackText = try await captureSelectionUsingClipboard(for: target)
        return CapturedSelection(text: fallbackText, source: .clipboardFallback, target: target, restoreAnchor: nil)
    }

    func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func probeSelectedTextFromAccessibility(processIdentifier: pid_t) -> AXSelectionProbe {
        guard isAccessibilityTrusted() else {
            return AXSelectionProbe(text: nil, details: "accessibility_not_trusted", restoreAnchor: nil)
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let systemElement = AXUIElementCreateSystemWide()

        let focusedCandidates = [
            copyElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute as CFString),
            copyElementAttribute(systemElement, attribute: kAXFocusedUIElementAttribute as CFString),
        ]

        var attempted: [String] = []

        for (index, candidate) in focusedCandidates.enumerated() {
            guard let element = candidate else { continue }
            attempted.append("candidate_\(index)_present")
            if let text = copyStringAttribute(element, attribute: kAXSelectedTextAttribute as CFString),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let selectedRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute as CFString)
                let restoreAnchor = selectedRange.map { SelectionRestoreAnchor(element: element, selectedRange: $0) }
                return AXSelectionProbe(text: text, details: attempted.joined(separator: ","), restoreAnchor: restoreAnchor)
            }
            attempted.append("candidate_\(index)_selected_text_empty")

            if let selectedRange = copyRangeAttribute(element, attribute: kAXSelectedTextRangeAttribute as CFString),
               let value = copyStringAttribute(element, attribute: kAXValueAttribute as CFString),
               let range = Range(selectedRange, in: value) {
                let selection = String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !selection.isEmpty {
                    attempted.append("candidate_\(index)_used_selected_range")
                    let restoreAnchor = SelectionRestoreAnchor(element: element, selectedRange: selectedRange)
                    return AXSelectionProbe(text: selection, details: attempted.joined(separator: ","), restoreAnchor: restoreAnchor)
                }
            }
            attempted.append("candidate_\(index)_selected_range_empty")
        }

        if attempted.isEmpty {
            attempted.append("no_focused_element")
        }

        return AXSelectionProbe(text: nil, details: attempted.joined(separator: ","), restoreAnchor: nil)
    }

    private func captureSelectionUsingClipboard(for target: ExternalApplicationTarget) async throws -> String {
        guard isAccessibilityTrusted() else {
            await logger.log(
                "selection",
                "Clipboard fallback aborted because accessibility is missing",
                metadata: ["app": target.displayName]
            )
            throw AppError.accessibilityPermissionMissing
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let initialChangeCount = pasteboard.changeCount
        let initialStringLength = pasteboard.string(forType: .string)?.count ?? 0
        defer {
            snapshot.restore(to: pasteboard)
        }

        await logger.log(
            "selection",
            "Clipboard fallback preparing copy",
            metadata: [
                "app": target.displayName,
                "frontmost_before_activate": frontmostAppDescription(),
                "pasteboard_change_count": "\(initialChangeCount)",
                "pasteboard_string_length": "\(initialStringLength)",
                "pasteboard_types": pasteboard.pasteboardItems?.flatMap(\.types).map(\.rawValue).joined(separator: ",") ?? "none",
            ]
        )

        for attempt in 1...fallbackAttempts {
            let focusStatus = accessibilityFocusStatus(processIdentifier: target.processIdentifier)

            await logger.log(
                "selection",
                "Clipboard fallback ready to copy",
                metadata: [
                    "app": target.displayName,
                    "attempt": "\(attempt)",
                    "focus_status": focusStatus,
                ]
            )

            for strategy in ClipboardCopyStrategy.allCases {
                let baselineChangeCount = pasteboard.changeCount
                await logger.log(
                    "selection",
                    "Clipboard fallback dispatching copy",
                    metadata: [
                        "app": target.displayName,
                        "attempt": "\(attempt)",
                        "strategy": strategy.rawValue,
                        "baseline_change_count": "\(baselineChangeCount)",
                    ]
                )

                try dispatchCopy(using: strategy, target: target)

                if let text = try await waitForClipboardChange(
                    pasteboard: pasteboard,
                    previousChangeCount: baselineChangeCount,
                    target: target,
                    attempt: attempt,
                    strategy: strategy
                ) {
                    await logger.log(
                        "selection",
                        "Clipboard fallback succeeded",
                        metadata: [
                            "app": target.displayName,
                            "attempt": "\(attempt)",
                            "strategy": strategy.rawValue,
                            "length": "\(text.count)",
                            "frontmost_after_copy": frontmostAppDescription(),
                        ]
                    )

                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AppError.emptySelection
                    }

                    return text
                }

                await logger.log(
                    "selection",
                    "Clipboard fallback strategy did not update pasteboard",
                    metadata: [
                        "app": target.displayName,
                        "attempt": "\(attempt)",
                        "strategy": strategy.rawValue,
                        "frontmost_after_strategy": frontmostAppDescription(),
                        "current_change_count": "\(pasteboard.changeCount)",
                    ]
                )

                try await Task.sleep(for: .milliseconds(120))
            }

            await logger.log(
                "selection",
                "Clipboard fallback attempt exhausted all strategies",
                metadata: [
                    "app": target.displayName,
                    "attempt": "\(attempt)",
                    "frontmost_after_attempt": frontmostAppDescription(),
                    "focus_status": accessibilityFocusStatus(processIdentifier: target.processIdentifier),
                ]
            )
        }

        throw AppError.clipboardCopyFailed
    }

    private func waitForClipboardChange(
        pasteboard: NSPasteboard,
        previousChangeCount: Int,
        target: ExternalApplicationTarget,
        attempt: Int,
        strategy: ClipboardCopyStrategy
    ) async throws -> String? {
        for poll in 1...20 {
            try await Task.sleep(for: .milliseconds(80))
            if pasteboard.changeCount != previousChangeCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                await logger.log(
                    "selection",
                    "Detected pasteboard update during fallback",
                    metadata: [
                        "app": target.displayName,
                        "attempt": "\(attempt)",
                        "strategy": strategy.rawValue,
                        "poll": "\(poll)",
                        "new_change_count": "\(pasteboard.changeCount)",
                        "text_length": "\(text.count)",
                    ]
                )
                return text
            }
        }
        return nil
    }

    private func copyElementAttribute(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let string = value as? String else {
            return nil
        }
        return string
    }

    private func copyRangeAttribute(_ element: AXUIElement, attribute: CFString) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let castedValue = axValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(castedValue) == .cfRange,
              AXValueGetValue(castedValue, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
    }

    private func frontmostAppDescription() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "none"
        }
        return "\(app.localizedName ?? app.bundleIdentifier ?? "Unknown")[\(app.processIdentifier)]"
    }

    private func waitForFrontmostApplication(_ target: ExternalApplicationTarget) async throws -> String {
        for _ in 1...frontmostActivationPollCount {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                try await Task.sleep(for: .milliseconds(120))
                return frontmostAppDescription()
            }
            try await Task.sleep(for: frontmostActivationPollInterval)
        }
        return frontmostAppDescription()
    }

    private func accessibilityFocusStatus(processIdentifier: pid_t) -> String {
        guard isAccessibilityTrusted() else {
            return "ax_untrusted"
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let systemElement = AXUIElementCreateSystemWide()
        let appFocused = copyElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute as CFString) != nil
        let systemFocused = copyElementAttribute(systemElement, attribute: kAXFocusedUIElementAttribute as CFString) != nil
        return "app_focused_element=\(appFocused),system_focused_element=\(systemFocused)"
    }

    private func dispatchCopy(using strategy: ClipboardCopyStrategy, target: ExternalApplicationTarget) throws {
        switch strategy {
        case .postToPid:
            try postCopyEvents(to: target.processIdentifier)
        case .systemEvents:
            try executeCopyScript(target: target)
        }
    }

    private func postCopyEvents(to processIdentifier: pid_t) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: false
              ) else {
            throw AppError.appleScriptFailed("Failed to create keyboard events for clipboard fallback.")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }

    private func executeCopyScript(target: ExternalApplicationTarget) throws {
        // Do not activate the target application here. If the target is a full-screen app
        // and we trigger this from a background process or accessory app, telling it to 
        // activate can force macOS to abruptly switch spaces to the main desktop.
        // Since the global hotkey is fired while the app is already frontmost,
        // sending the keystroke via System Events is sufficient.
        let script = """
        tell application "System Events"
            keystroke "c" using command down
        end tell
        """

        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            throw AppError.appleScriptFailed(errorInfo.description)
        }
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct AXSelectionProbe {
    var text: String?
    var details: String
    var restoreAnchor: SelectionRestoreAnchor?
}

private enum ClipboardCopyStrategy: String, CaseIterable {
    case postToPid = "post_to_pid"
    case systemEvents = "system_events"
}
