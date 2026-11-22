import AppKit
import Carbon
import Foundation

/// Registers a system-wide customizable macOS hotkey supporting:
/// 1. Any key combination OR single regular key (e.g. `⌥ Space`, `F5`, `` ` ``) via Carbon RegisterEventHotKey (zero permissions).
/// 2. Single modifier key tap-and-release (e.g. `右 ⌥`, `Fn 🌐`, `右 ⌘`) via global+local `.flagsChanged` monitoring.
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private var modifierTapDownTime: TimeInterval?
    private var modifierTapInvalidated: Bool = false

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

        switch config.kind {
        case .keyCombo:
            registerCarbonHotKey(keyCode: config.keyCode, modifiers: config.modifiers)
        case .singleModifier:
            registerSingleModifierTap(targetKeyCode: config.keyCode)
        }
    }

    private func registerCarbonHotKey(keyCode: UInt32, modifiers: UInt32) {
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
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func registerSingleModifierTap(targetKeyCode: UInt32) {
        guard let targetFlag = GlobalHotkeyConfig.modifierFlag(for: targetKeyCode) else { return }
        modifierTapDownTime = nil
        modifierTapInvalidated = false

        let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

        let handleFlags: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let code = UInt32(event.keyCode)
            let active = event.modifierFlags.intersection(relevantMask)

            if code == targetKeyCode {
                if active.contains(targetFlag) {
                    // Key pressed down: only valid if NO other modifier is held simultaneously
                    if active == targetFlag {
                        self.modifierTapDownTime = ProcessInfo.processInfo.systemUptime
                        self.modifierTapInvalidated = false
                    } else {
                        self.modifierTapDownTime = nil
                        self.modifierTapInvalidated = true
                    }
                } else {
                    // Key released: trigger only if it was a clean quick tap (< 0.45s) with no other keys pressed
                    if let downTime = self.modifierTapDownTime, !self.modifierTapInvalidated {
                        let elapsed = ProcessInfo.processInfo.systemUptime - downTime
                        if elapsed <= 0.45 {
                            self.handleTriggered()
                        }
                    }
                    self.modifierTapDownTime = nil
                    self.modifierTapInvalidated = false
                }
            } else if self.modifierTapDownTime != nil {
                // Another modifier key was pressed while holding target modifier -> cancel tap
                self.modifierTapInvalidated = true
            }
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in handleFlags(event) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlags(event)
            return event
        }

        // If any regular key is pressed while holding the modifier (e.g. Option + C), cancel the single-tap!
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in self?.modifierTapInvalidated = true }
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.modifierTapInvalidated = true
            return event
        }
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
        if let m = globalFlagsMonitor {
            NSEvent.removeMonitor(m)
            globalFlagsMonitor = nil
        }
        if let m = localFlagsMonitor {
            NSEvent.removeMonitor(m)
            localFlagsMonitor = nil
        }
        if let m = globalKeyDownMonitor {
            NSEvent.removeMonitor(m)
            globalKeyDownMonitor = nil
        }
        if let m = localKeyDownMonitor {
            NSEvent.removeMonitor(m)
            localKeyDownMonitor = nil
        }
        modifierTapDownTime = nil
        modifierTapInvalidated = false
    }

    private func handleTriggered() {
        onTrigger?()
    }
}
