import Carbon
import Foundation

/// Registers a zero-permission system-wide customizable macOS hotkey via Carbon RegisterEventHotKey
/// so the user can start/stop voice input from inside any app without Accessibility permissions.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private var lastEnabled: Bool = false
    private var lastConfig: GlobalHotkeyConfig = .defaultOptionSpace

    private static let hotKeySignature: OSType = 0x5254444F // 'RTDO'
    private static let hotKeyID: UInt32 = 1

    private init() {}

    func configure(enabled: Bool, config: GlobalHotkeyConfig, onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        self.lastEnabled = enabled
        self.lastConfig = config
        if enabled {
            register(config: config)
        } else {
            unregister()
        }
    }

    /// Temporarily pauses the registered global shortcut while the user records a new shortcut in Settings.
    func pauseTemporarily() {
        unregister()
    }

    /// Restores the active shortcut once shortcut recording finishes or is cancelled.
    func resumeIfNeeded() {
        if lastEnabled {
            register(config: lastConfig)
        }
    }

    private func register(config: GlobalHotkeyConfig) {
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
            config.keyCode,
            config.modifiers,
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
