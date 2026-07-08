import Carbon.HIToolbox

// A system-wide hotkey via Carbon RegisterEventHotKey. Fires from any
// app; the OS matches key down/up itself, so a physical press never leaves a
// modifier stuck (the earlier "stuck ⌘+⌥" was from synthetic events, not this).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
                me.action()
                return noErr
            },
            1, &spec, selfPtr, &eventHandler
        )

        let id = EventHotKeyID(signature: OSType(0x54505354), id: 1) // 'TPST'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
