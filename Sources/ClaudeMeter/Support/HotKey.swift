import AppKit
import Carbon.HIToolbox

/// A single global hotkey via Carbon (no Accessibility permission required, works for an
/// agent app). Defaults to ⌥⌘U to toggle the popover.
final class HotKey {
    var onActivate: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// `keyCode` is a Carbon virtual key (e.g. `kVK_ANSI_U`); `modifiers` a Carbon mask
    /// (`cmdKey | optionKey`).
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_U), modifiers: UInt32 = UInt32(cmdKey | optionKey)) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.onActivate?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef,
        )

        let id = EventHotKeyID(signature: OSType(0x434D_5452), id: 1) // 'CMTR'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
