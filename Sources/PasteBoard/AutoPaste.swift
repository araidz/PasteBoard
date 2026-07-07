import Cocoa
import ApplicationServices
import Carbon.HIToolbox

/// Reactivates the app you were in and synthesizes ⌘V so the picked item lands
/// where you were typing. Requires the Accessibility permission; without it the
/// commit degrades to copy-only (the item is on the clipboard, paste it yourself).
enum AutoPaste {
    enum Action: Equatable { case autoPaste, copyOnly }

    /// What a commit should do. Pure, so the decision is unit-testable without
    /// touching the pasteboard, TCC, or another app.
    static func action(autoPasteEnabled: Bool, trusted: Bool, targetIsSelf: Bool) -> Action {
        (autoPasteEnabled && trusted && !targetIsSelf) ? .autoPaste : .copyOnly
    }

    /// Whether we currently hold the Accessibility permission needed to paste.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt for Accessibility (opens System Settings). Returns current trust.
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // Grace period for the target app to become frontmost before we synthesize ⌘V.
    // ponytail: fixed delay, not an activation observer — 0.12s is comfortable on
    // Apple Silicon. If focus-return ever feels racy, key off
    // NSWorkspace.didActivateApplicationNotification instead.
    private static let activationDelay: TimeInterval = 0.12

    /// Bring `app` forward and paste the current clipboard into it.
    static func paste(into app: NSRunningApplication?) {
        activate(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
    }

    private static func activate(_ app: NSRunningApplication?) {
        guard let app else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmd = CGKeyCode(kVK_Command)
        let v = CGKeyCode(kVK_ANSI_V)
        // Explicitly press AND release Command around V. Setting only the flag (no
        // real Command key-up) leaves the modifier dangling in the target's event
        // stream — its next click inherits it (Terminal then shows a "+" cursor).
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
