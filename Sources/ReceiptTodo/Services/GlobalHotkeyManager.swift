import Carbon
import Foundation

/// Registers a zero-permission system-wide macOS hotkey (Option + Space) via Carbon RegisterEventHotKey
/// so the user can start/stop voice input from inside any app without Accessibility permissions.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private static let hotKeySignature: OSType = 0x5254444F // 'RTDO'
    private static let hotKeyID: UInt32 = 1

    private init() {}

    func setEnabled(_ enabled: Bool, onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        if enabled {
            registerOptionSpace()
        } else {
            unregister()
        }
    }

    private func registerOptionSpace() {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let statusHandler = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if err == noErr && hkID.signature == GlobalHotkeyManager.hotKeySignature {
                    Task { @MainActor in
                        GlobalHotkeyManager.shared.handleTriggered()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard statusHandler == noErr else { return }

        let hkID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    private func handleTriggered() {
        onTrigger?()
    }
}
