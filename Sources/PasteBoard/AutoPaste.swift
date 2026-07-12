import Cocoa
import Carbon.HIToolbox

// Auto-paste: reactivate the previously-frontmost app and synthesize
// ⌘V so the committed item lands where the user was typing. Needs Accessibility
// (to post events into another app); without it we degrade to copy-only.
enum AutoPaste {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility (opens System Settings). Returns current trust.
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Bring `app` forward, then paste the current clipboard into it.
    static func paste(into app: NSRunningApplication?) {
        guard let app else { return }
        if #available(macOS 14.0, *) {
            app.activate(from: NSRunningApplication.current, options: [])
        } else {
            app.activate()
        }
        // Small grace period for the target to become frontmost before ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            postCommandV()
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmd = CGKeyCode(kVK_Command)
        let v = CGKeyCode(kVK_ANSI_V)
        // Fully specify the modifier state on every event: cmdDown and both V events
        // carry .maskCommand, and cmdUp clears it. Terminal rejects a synthetic ⌘V whose
        // Command key-down lacks the flag (system beep, no paste) even though most apps
        // tolerate it; clearing on cmdUp also prevents a dangling modifier (the "+" cursor).
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: false)
        cmdDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        cmdUp?.flags = []
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
