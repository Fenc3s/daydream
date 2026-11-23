import Carbon
import Foundation

struct HotKeyBinding {
    var commandID: UUID
    var title: String
    var shortcut: KeyboardShortcut
}

final class HotKeyService {
    static let shared = HotKeyService()

    private static let signature = OSType(0x44594452)

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var bindingsByCarbonID: [UInt32: HotKeyBinding] = [:]
    private var onPressed: ((HotKeyBinding) -> Void)?
    private var nextID: UInt32 = 1

    private init() {
        installHandlerIfNeeded()
    }

    func configure(bindings: [HotKeyBinding], onPressed: @escaping (HotKeyBinding) -> Void) -> [String] {
        unregisterAll()
        self.onPressed = onPressed

        var issues: [String] = []
        nextID = 1

        for binding in bindings {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextID)
            let status = RegisterEventHotKey(
                UInt32(binding.shortcut.keyCode),
                binding.shortcut.carbonModifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let hotKeyRef {
                hotKeyRefs[nextID] = hotKeyRef
                bindingsByCarbonID[nextID] = binding
                nextID += 1
            } else {
                issues.append("Failed to register \(binding.title) (\(binding.shortcut.displayString)), status \(status)")
            }
        }

        return issues
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        bindingsByCarbonID.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
                return service.handle(event: event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handle(event: EventRef?) -> OSStatus {
        guard let event else { return noErr }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == Self.signature,
              let binding = bindingsByCarbonID[hotKeyID.id] else {
            return status
        }

        onPressed?(binding)
        return noErr
    }
}
