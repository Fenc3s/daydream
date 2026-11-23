import Carbon
import SwiftUI

struct ShortcutRecorderField: View {
    var shortcut: KeyboardShortcut?
    var hasConflict: Bool
    var allowsClearing = true
    var onChange: (KeyboardShortcut?) -> Void

    @State private var isRecording = false
    @State private var warningMessage: String?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(isRecording ? "Type Shortcut…" : (shortcut?.displayString ?? "Record Shortcut")) {
                    toggleRecording()
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .orange : .accentColor)

                if allowsClearing, shortcut != nil {
                    Button("Clear") {
                        stopRecording()
                        onChange(nil)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if hasConflict {
                Label("This shortcut conflicts with another command.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            } else if let warningMessage {
                Text(warningMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Supported keys: A-Z, 0-9, punctuation, Space/Return/Tab, Arrows, F1-F12. Global shortcuts must include Command, Option, or Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        warningMessage = nil

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)),
               ShortcutModifiers(event.modifierFlags).isEmpty {
                onChange(nil)
                stopRecording()
                return nil
            }

            guard let shortcut = KeyboardShortcut.capture(from: event) else {
                warningMessage = "Unsupported key. Use letters, numbers, punctuation, Space/Return/Tab, Arrows, or F1-F12."
                return nil
            }

            guard shortcut.hasPrimaryModifier else {
                warningMessage = "Include Command, Option, or Control."
                return nil
            }

            onChange(shortcut)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
