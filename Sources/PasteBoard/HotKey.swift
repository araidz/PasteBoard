import Carbon.HIToolbox

/// A single global hotkey registered through Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the one system-wide shortcut mechanism that needs **no**
/// special permission (unlike `CGEventTap`, which requires Accessibility, or
/// `NSEvent` global monitors, which can observe but not consume the event).
/// The handler fires on the main run loop, so `callback` runs on the main thread.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: () -> Void

    /// - Parameters:
    ///   - keyCode: a virtual key code (e.g. `kVK_ANSI_V`).
    ///   - modifiers: Carbon modifier mask (e.g. `cmdKey | optionKey`).
    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().callback()
            return noErr
        }, 1, &spec, context, &handlerRef)

        // 'PBHK' — an arbitrary but stable four-char signature for our hotkey.
        let id = EventHotKeyID(signature: OSType(0x50424846), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
