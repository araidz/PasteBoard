import Cocoa
import SwiftUI
import ServiceManagement

/// Wraps the macOS 13+ login-item API so the app can launch itself at startup.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("PasteBoard: failed to update login item — \(error.localizedDescription)")
        }
    }
}

/// A borderless panel that can still become key/main so the search field and
/// keyboard navigation work without a title bar.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var clipboardManager = ClipboardManager()
    var timer: Timer?
    var keyMonitor: Any?
    var dismissMonitor: Any?

    // How often the pasteboard is polled for new content (no system notification exists).
    private static let pollInterval: TimeInterval = 0.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "PasteBoard")
            button.target = self
            button.action = #selector(togglePanel)
        }

        // Borderless, floating, user-resizable panel — no title bar at all.
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 540),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false          // we dismiss manually (see dismissMonitor)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: 260, height: 420)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.setFrameAutosaveName("PasteBoardPanel")

        panel.contentViewController = NSHostingController(
            rootView: ClipboardHistoryView(manager: clipboardManager, onItemSelected: { [weak self] in
                self?.panel.orderOut(nil)
            })
        )

        // Dismiss the panel when the user clicks anywhere outside it.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            self.panel.orderOut(nil)
        }

        // Listen for clipboard captures to blink the menu bar icon
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardDidCapture),
            name: .clipboardDidCapture,
            object: nil
        )

        startMonitoring()
        installKeyMonitor()

        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Launch at login is on by default on first run; the user can toggle it
        // off in the panel (or System Settings) and we respect that afterward.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didInitializeLoginItem") {
            LoginItem.setEnabled(true)
            defaults.set(true, forKey: "didInitializeLoginItem")
        }

        // A pure menu-bar app shouldn't show any window at launch. SwiftUI's
        // Settings scene (or window-state restoration) can present an empty
        // "PasteBoard Settings" window. Close only *titled* windows — our panel
        // and the status-bar item's window are borderless, so they're untouched.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.close()
            }
        }
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.clipboardManager.checkForChanges()
        }
    }

    /// Arrow keys move the selection; Return pastes the selected item and closes.
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return event }
            switch event.keyCode {
            case 125: // down arrow
                self.clipboardManager.moveSelection(by: 1)
                return nil
            case 126: // up arrow
                self.clipboardManager.moveSelection(by: -1)
                return nil
            case 36, 76: // return / keypad enter
                // Use the highlighted row, or fall back to the top item so Return
                // pastes the most recent entry even when nothing is selected yet.
                if let item = self.clipboardManager.selectedItem ?? self.clipboardManager.filteredItems.first {
                    self.clipboardManager.pasteItem(item)
                    self.panel.orderOut(nil)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    @objc func togglePanel() {
        guard let button = statusItem.button else { return }

        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        // Don't pre-select a row — the panel opens with nothing highlighted, like a
        // native menu. Hover or the first arrow-key press establishes the selection.
        clipboardManager.selectedItemID = nil
        positionPanel(below: button)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Place the panel just beneath the menu bar icon, kept on screen.
    private func positionPanel(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else {
            panel.center()
            return
        }
        let buttonRectInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(
            x: buttonRectInScreen.midX - panel.frame.width / 2,
            y: buttonRectInScreen.minY - panel.frame.height - 4
        )
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    @objc func clipboardDidCapture() {
        guard let button = statusItem.button else { return }
        let blink = {
            button.contentTintColor = .controlAccentColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                button.contentTintColor = nil
            }
        }
        blink()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { blink() }
    }
}

// NOTE: reconstructed — notification name used to signal a capture.
extension Notification.Name {
    static let clipboardDidCapture = Notification.Name("clipboardDidCapture")
}
