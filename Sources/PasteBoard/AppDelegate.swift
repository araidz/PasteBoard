import Cocoa
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

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

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var clipboardManager = ClipboardManager()
    var timer: Timer?
    var keyMonitor: Any?
    var dismissMonitor: Any?
    var hotKey: HotKey?
    // The app that was frontmost when the panel opened — where auto-paste sends the item.
    var capturedApp: NSRunningApplication?

    // How often the pasteboard is polled for new content (no system notification exists).
    private static let pollInterval: TimeInterval = 0.5

    // Corner radius of the panel's glass surface, tuned to match macOS 26 menus.
    private static let panelCornerRadius: CGFloat = 13

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "PasteBoard")
        }
        // Clicking the icon shows a native menu of options; the floating history
        // is opened by the ⌥⌘V hotkey (or the menu's "Open Clipboard History").
        statusItem.menu = buildStatusMenu()

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

        let hostingView = NSHostingView(
            rootView: ClipboardHistoryView(
                manager: clipboardManager,
                onCommit: { [weak self] in self?.commit($0) },
                onCommitPath: { [weak self] in self?.commitPath($0) }
            )
        )
        if #available(macOS 26.0, *) {
            // Embed the SwiftUI content in the system's Liquid Glass surface. This
            // is the exact view menus use, so the material, the rounded corners, and
            // the drop shadow all match a real menu as a single unit — which also
            // avoids the corner artifacts you get from hand-clipping a glass view.
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.panelCornerRadius
            glass.contentView = hostingView
            panel.contentView = glass
            // The glass surface casts its own correctly-rounded shadow. The window's
            // automatic shadow is derived from the square content silhouette, so
            // leaving it on traces a dark, slightly-square fringe around the rounded
            // corners (it doesn't follow the radius). Turn it off so only the glass's
            // own shadow remains — exactly like a real menu.
            panel.hasShadow = false
        } else {
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
        }

        // Dismiss the panel when the user clicks anywhere outside it.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            // Ignore clicks on our own status item — those open its menu, which
            // presents itself; hiding the panel here would fight that.
            if let button = self.statusItem.button, let win = button.window {
                let frameInScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
                if frameInScreen.contains(NSEvent.mouseLocation) { return }
            }
            self.hidePanel()
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

        // ⌥⌘V opens the history over whatever app you're in (needs no permission).
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggle(nearCursor: true)
        }

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

    /// Keyboard while the panel is open: ⌘1–9 quick-paste, ⌘P pin, ⌘⌫ delete, ↑/↓ select, ⏎ paste, Esc close.
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return event }
            // ⌘ shortcuts while the panel is open.
            if event.modifierFlags.contains(.command) {
                // ⌘1–9 pastes the Nth item (layout-robust via the typed character).
                if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...9).contains(digit) {
                    let list = self.clipboardManager.filteredItems
                    if digit <= list.count { self.commit(list[digit - 1]) }
                    return nil
                }
                // ⌘P pin/unpin, ⌘⌫ delete — act on the selected entry only.
                if let selected = self.clipboardManager.selectedItem {
                    if event.charactersIgnoringModifiers == "p" {
                        self.clipboardManager.togglePin(selected)
                        return nil
                    }
                    if event.keyCode == 51 {   // delete / backspace
                        self.deleteSelected()
                        return nil
                    }
                }
                return event   // other ⌘ combos pass through (copy, select-all, …)
            }
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
                    self.commit(item)
                    return nil
                }
                return event
            case 53: // esc
                self.hidePanel()
                return nil
            default:
                return event
            }
        }
    }

    /// Delete the selected entry, keeping a neighbour selected for repeat deletes.
    private func deleteSelected() {
        guard let item = clipboardManager.selectedItem else { return }
        let index = clipboardManager.filteredItems.firstIndex { $0.id == item.id }
        clipboardManager.deleteItem(item)
        let remaining = clipboardManager.filteredItems
        if let index, !remaining.isEmpty {
            clipboardManager.selectedItemID = remaining[min(index, remaining.count - 1)].id
        }
    }

    // MARK: - Menu-bar menu

    // Tags for the items whose state we refresh each time the menu opens.
    private enum MenuTag: Int { case launchAtLogin = 1, autoPaste = 2, accessibility = 3, historyLimit = 4 }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "PasteBoard", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        addItem(to: menu, "Open Clipboard History (⌥⌘V)", #selector(menuOpenHistory))
        menu.addItem(.separator())

        addItem(to: menu, "Launch at Login", #selector(menuToggleLaunchAtLogin), tag: MenuTag.launchAtLogin.rawValue)
        addItem(to: menu, "Paste Directly Into App", #selector(menuToggleAutoPaste), tag: MenuTag.autoPaste.rawValue)
        addItem(to: menu, "Enable Accessibility (for auto-paste)…", #selector(menuEnableAccessibility), tag: MenuTag.accessibility.rawValue)

        let limitItem = NSMenuItem(title: "History Limit", action: nil, keyEquivalent: "")
        limitItem.tag = MenuTag.historyLimit.rawValue
        let limitMenu = NSMenu()
        for limit in [50, 100, 200, 500, 1000] {
            addItem(to: limitMenu, "\(limit) items", #selector(menuSetHistoryLimit(_:)), tag: limit)
        }
        limitItem.submenu = limitMenu
        menu.addItem(limitItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PasteBoard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: MenuTag.launchAtLogin.rawValue)?.state = LoginItem.isEnabled ? .on : .off
        menu.item(withTag: MenuTag.autoPaste.rawValue)?.state = autoPasteEnabled ? .on : .off
        if let access = menu.item(withTag: MenuTag.accessibility.rawValue) {
            let trusted = AutoPaste.isTrusted
            access.state = trusted ? .on : .off
            access.title = trusted ? "Accessibility Enabled" : "Enable Accessibility (for auto-paste)…"
        }
        if let submenu = menu.item(withTag: MenuTag.historyLimit.rawValue)?.submenu {
            for item in submenu.items { item.state = (item.tag == clipboardManager.maxItems) ? .on : .off }
        }
    }

    @objc private func menuOpenHistory() { toggle(nearCursor: false) }
    @objc private func menuToggleLaunchAtLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func menuToggleAutoPaste() { autoPasteEnabled.toggle() }
    @objc private func menuEnableAccessibility() { AutoPaste.requestPermission() }
    @objc private func menuSetHistoryLimit(_ sender: NSMenuItem) { clipboardManager.maxItems = sender.tag }

    /// Show or hide the history. `nearCursor` positions it at the pointer (hotkey)
    /// instead of under the menu-bar icon (click).
    func toggle(nearCursor: Bool) {
        if panel.isVisible {
            hidePanel()
        } else {
            // Capture the frontmost app before we activate ourselves — that's the
            // app auto-paste will send the picked item back into.
            capturedApp = NSWorkspace.shared.frontmostApplication
            showPanel(nearCursor: nearCursor)
        }
    }

    // MARK: - Commit (paste)

    /// Whether to auto-paste into the previous app (default on). Persisted.
    var autoPasteEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoPasteEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPasteEnabled") }
    }

    /// Put an item on the clipboard, close the panel, and (if permitted) paste it
    /// straight back into the app you came from.
    func commit(_ item: ClipboardItem) {
        clipboardManager.pasteItem(item)
        finishCommit()
    }

    /// Commit a single member of a multi-file group.
    func commitPath(_ path: String) {
        clipboardManager.pasteSubPath(path)
        finishCommit()
    }

    private func finishCommit() {
        let target = capturedApp
        hidePanel()
        let targetIsSelf = target?.bundleIdentifier == Bundle.main.bundleIdentifier
        let action = AutoPaste.action(autoPasteEnabled: autoPasteEnabled,
                                      trusted: AutoPaste.isTrusted,
                                      targetIsSelf: targetIsSelf)
        if action == .autoPaste {
            AutoPaste.paste(into: target)
        }
    }

    /// Open the panel — under the menu-bar icon, or at the pointer for the hotkey.
    private func showPanel(nearCursor: Bool) {
        // Don't pre-select a row — hover or the first arrow key establishes it.
        clipboardManager.selectedItemID = nil
        if nearCursor {
            positionPanelAtCursor()
        } else if let button = statusItem.button {
            positionPanel(below: button)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        // Open fresh: clear any prior query and focus the search field.
        DispatchQueue.main.async {
            self.clipboardManager.searchText = ""
            NotificationCenter.default.post(name: .panelDidShow, object: nil)
        }
    }

    /// Place the panel near the mouse pointer, clamped on screen.
    private func positionPanelAtCursor() {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - 8, y: mouse.y - panel.frame.height + 8)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    /// Close the panel. All dismissal paths (toggle, click-outside, paste) funnel
    /// through here.
    private func hidePanel() {
        panel.orderOut(nil)
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
    static let panelDidShow = Notification.Name("panelDidShow")
}
