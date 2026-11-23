import Carbon
import SwiftUI

struct ShortcutRecorderField: View {
    var shortcut: KeyboardShortcut?
    var hasConflict: Bool
    var allowsClearing = true
    var onChange: (KeyboardShortcut?) -> Void

    @State private var isRecording = false
    @State private var isHovering = false
    @State private var warningMessage: String?
    @State private var eventMonitor: Any?

    private static let supportedKeysHelp =
        "Supported keys: A–Z, 0–9, punctuation, Space/Return/Tab, Arrows, F1–F12. Global shortcuts must include Command, Option, or Control."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    toggleRecording()
                } label: {
                    HStack(spacing: 6) {
                        if isRecording {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                            Text("Press Shortcut…")
                                .font(.system(.callout, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        } else if let shortcut {
                            Text(shortcut.displayString)
                                .font(.system(.callout, design: .rounded, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        } else {
                            Image(systemName: "command")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("Record Shortcut")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minWidth: 112)
                    .background(recorderBackground)
                    .overlay(recorderBorder)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                }
                .help(isRecording ? "Press Escape to cancel" : Self.supportedKeysHelp)

                if allowsClearing, shortcut != nil, !isRecording {
                    Button {
                        stopRecording()
                        onChange(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear shortcut")
                    .help("Clear shortcut")
                }
            }

            if hasConflict {
                Label("This shortcut conflicts with another command.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let warningMessage {
                Label(warningMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isRecording {
                Text("Press keys with ⌘, ⌥, or ⌃. Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var recorderBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                isRecording
                    ? Color.accentColor.opacity(0.10)
                    : (isHovering ? Color.primary.opacity(0.06) : Color.primary.opacity(0.035))
            )
    }

    private var recorderBorder: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
                borderColor,
                lineWidth: isRecording ? 1.5 : 0.75
            )
    }

    private var borderColor: Color {
        if isRecording {
            return .accentColor
        }
        if hasConflict {
            return .orange.opacity(0.7)
        }
        return Color(nsColor: .separatorColor).opacity(isHovering ? 0.9 : 0.6)
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
                if allowsClearing {
                    onChange(nil)
                }
                stopRecording()
                return nil
            }

            guard let shortcut = KeyboardShortcut.capture(from: event) else {
                warningMessage = "Unsupported key. Use letters, numbers, punctuation, Space/Return/Tab, Arrows, or F1–F12."
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
