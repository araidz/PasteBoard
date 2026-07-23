import Carbon.HIToolbox

// A user-pickable global hotkey. Carbon's RegisterEventHotKey only intercepts a
// combo while it's registered, so switching presets (which releases the old
// HotKey) automatically returns the previous combo to its macOS default.
struct HotKeyPreset: Identifiable {
    let id: String
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32

    // Order shown in the gear menu; first is the default.
    static let all: [HotKeyPreset] = [
        HotKeyPreset(id: "ctrl-cmd-v",     label: "⌃⌘V",  keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | cmdKey)),
        HotKeyPreset(id: "ctrl-opt-v",     label: "⌃⌥V",  keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(id: "ctrl-opt-cmd-v", label: "⌃⌥⌘V", keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotKeyPreset(id: "shift-cmd-v",    label: "⇧⌘V",  keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(shiftKey | cmdKey)),
        HotKeyPreset(id: "opt-cmd-v",      label: "⌥⌘V",  keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey)),
    ]

    // The selected preset, persisted under "hotKeyPresetID". Falls back to the
    // default if unset or pointing at a preset that no longer exists.
    static var current: HotKeyPreset {
        let id = UserDefaults.standard.string(forKey: "hotKeyPresetID")
        return all.first { $0.id == id } ?? all[0]
    }
}

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
        // Use passRetained so the HotKey stays alive while the handler is installed.
        // ponytail: passRetained keeps HotKey alive for the Carbon callback lifetime — leaks if deinit never runs (e.g. orphaned ref).
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
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
        // Balance the passRetained in init. The assertion is a development
        // aid — passUnretained(self) never returns nil, but the release()
        // only matters if the retain in init actually balanced.
        Unmanaged<HotKey>.passUnretained(self).release()
    }
}
