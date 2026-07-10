import Cocoa
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

// The app delegate: menu-bar item, global ⌥⌘V hotkey, the clipboard-capture timer,
// the floating history panel, keyboard navigation, and commit → auto-paste.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var capturedApp: NSRunningApplication?   // where auto-paste sends the item
    private var hotKey: HotKey?
    private var pollTimer: Timer?
    private var dismissMonitor: Any?
    private var lastCloseTime = Date.distantPast   // guards the toggle against reopen-on-close
    private var lastOpenFromIcon = false            // icon click → center under icon; hotkey → at cursor

    private let clipboardManager = ClipboardManager()

    // Auto-paste preference (gear menu: "Paste Directly Into App"); default on.
    private var autoPasteEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoPasteEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPasteEnabled") }
    }

    // Launch at login via SMAppService (only effective for the packaged .app; the dev
    // binary isn't a registered bundle, so register() throws — logged, harmless).
    private var isLaunchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("launch-at-login toggle failed: \(error)") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "clipboard.fill",
            accessibilityDescription: "PasteBoard"
        )

        // Clicking the menu-bar icon toggles the panel; all settings live in the
        // in-panel gear menu.
        statusItem.button?.action = #selector(iconClicked)
        statusItem.button?.target = self

        installKeyMonitor()
        startMonitoring()
        // Flash the menu-bar icon when something is captured.
        NotificationCenter.default.addObserver(self, selector: #selector(flashIcon), name: .clipboardDidCapture, object: nil)
        // Dismiss when the user clicks outside our window (global monitor only sees
        // clicks destined for OTHER apps, so clicks inside our window won't fire it).
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.closeWindow()
        }
        // ⌥⌘V from any app opens/closes the window (captures the target at press time).
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.lastOpenFromIcon = false
            self?.toggleWindow()
        }
        // After an update macOS can drop the Accessibility grant (self-signed apps
        // re-verify on each new binary). If auto-paste is on but we're no longer trusted,
        // nudge to re-enable — deferred so the menu-bar item is up first. Silent when trusted.
        if autoPasteEnabled && !AutoPaste.isTrusted {
            DispatchQueue.main.async { AutoPaste.requestPermission() }
        }
    }

    // MARK: - Clipboard capture

    private func startMonitoring() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.clipboardManager.checkForChanges()
        }
    }

    // Briefly flash the icon to the outline clipboard as a capture confirmation, then back to full.
    @objc private func flashIcon() {
        statusItem.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Captured")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.statusItem.button?.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: "PasteBoard")
        }
    }

    // Place the panel just below the mouse cursor, clamped to the active screen.
    private func positionNearCursor(_ w: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = w.frame.size
        var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        origin.x = min(max(vf.minX, origin.x), vf.maxX - size.width)
        origin.y = min(max(vf.minY, origin.y), vf.maxY - size.height)
        w.setFrameOrigin(origin)
    }

    // Menu-bar icon click: remember the anchor so the panel centers under the icon.
    @objc private func iconClicked() {
        lastOpenFromIcon = true
        toggleWindow()
    }

    // Center the panel horizontally under the menu-bar icon, top just below the menu bar.
    private func positionUnderIcon(_ w: NSWindow) {
        guard let iconWindow = statusItem.button?.window else { positionNearCursor(w); return }
        let iconFrame = iconWindow.frame
        let vf = (iconWindow.screen ?? NSScreen.main)?.visibleFrame ?? iconFrame
        let size = w.frame.size
        var origin = NSPoint(x: iconFrame.midX - size.width / 2, y: iconFrame.minY - size.height)
        origin.x = min(max(vf.minX, origin.x), vf.maxX - size.width)
        origin.y = min(max(vf.minY, origin.y), vf.maxY - size.height)
        w.setFrameOrigin(origin)
    }

    @objc private func toggleWindow() {
        if let w = window, w.isVisible {
            closeWindow()
        } else {
            // The outside-click monitor also fires on this status-item click and may have
            // just closed the panel — don't immediately reopen it.
            if Date().timeIntervalSince(lastCloseTime) < 0.2 { return }
            openWindow()
        }
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        // Borderless, non-activating floating panel so opening it never steals focus
        // from the app you'll paste back into; content is wrapped in Liquid Glass on
        // macOS 26+.
        let w = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 520),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        // Lock the panel to a fixed size so it always opens at 290×520, whether the
        // history list is empty or full.
        w.contentMinSize = NSSize(width: 290, height: 520)
        w.contentMaxSize = NSSize(width: 290, height: 520)

        let hosting = NSHostingView(
            rootView: HistoryView(
                manager: clipboardManager,
                onCommit: { [weak self] item in self?.commit(item) },
                onCommitPath: { [weak self] path in self?.commitPath(path) },
                onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
                isLaunchAtLogin: { [weak self] in self?.isLaunchAtLogin ?? false },
                onEnableAccessibility: { AutoPaste.requestPermission() },
                isTrusted: { AutoPaste.isTrusted },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 13
            glass.contentView = hosting
            w.contentView = glass
            w.hasShadow = false
        } else {
            // Pre-macOS-26: a menu-material blurred surface as the Liquid Glass fallback.
            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 290, height: 520))
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 13
            effect.layer?.masksToBounds = true
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            w.contentView = effect
        }
        return w
    }

    @objc private func openWindow() {
        let w = window ?? makeWindow()
        window = w
        // Capture the app to paste back into — never ourselves (compare by pid so
        // it's robust whether or not this build has a bundle id).
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            capturedApp = front
        }
        clipboardManager.selectedItemID = nil
        clipboardManager.searchText = ""       // fresh, unfiltered list on each open
        clipboardManager.isPreviewing = false
        if lastOpenFromIcon { positionUnderIcon(w) } else { positionNearCursor(w) }
        w.makeKeyAndOrderFront(nil)
        // Focus the search field once the panel is key (next runloop).
        DispatchQueue.main.async { NotificationCenter.default.post(name: .panelDidShow, object: nil) }
    }

    private func closeWindow() {
        window?.orderOut(nil)
        lastCloseTime = Date()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return event }
            let list = self.clipboardManager.filteredItems

            // ⌘-shortcuts: ⌘1–9 quick-paste the Nth visible row, ⌘P pin/unpin, ⌘⌫ delete.
            if event.modifierFlags.contains(.command) {
                if let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n) {
                    if list.indices.contains(n - 1) { self.commit(list[n - 1]) }
                    return nil
                }
                switch event.keyCode {
                case 35:  // P — pin/unpin the highlighted row
                    if let item = self.clipboardManager.selectedItem { self.clipboardManager.togglePin(item) }
                    return nil
                case 51:  // ⌫ — delete the highlighted row (pinned rows are protected)
                    if let item = self.clipboardManager.selectedItem { self.clipboardManager.deleteItem(item) }
                    return nil
                case 16:  // Y — toggle the full-content preview overlay
                    self.clipboardManager.isPreviewing.toggle()
                    return nil
                default:
                    return event
                }
            }

            switch event.keyCode {
            case 125: self.clipboardManager.moveSelection(by: 1); return nil   // down
            case 126: self.clipboardManager.moveSelection(by: -1); return nil  // up
            case 36, 76:                                                       // return / keypad enter
                if let item = self.clipboardManager.selectedItem ?? list.first {
                    self.commit(item); return nil
                }
                return event
            case 49 where self.clipboardManager.isPreviewing:              // space — closes preview
                self.clipboardManager.isPreviewing = false
                return nil
            case 53:                                                           // esc
                if self.clipboardManager.isPreviewing { self.clipboardManager.isPreviewing = false }
                else { self.closeWindow() }
                return nil
            default: return event
            }
        }
    }

    // MARK: - Commit + auto-paste

    private func commit(_ item: ClipboardItem) {
        // Terminals can't accept a file-url or image via synthetic ⌘V (it beeps). For
        // files/folders, paste the shell-escaped path(s) as text — same result as
        // dragging the file in. Image data has no text form → copy-only (no ⌘V).
        if capturedIsTerminal {
            switch item.type {
            case .file, .folder:
                clipboardManager.pasteText((item.filePaths ?? []).map(Self.shellEscape).joined(separator: " "))
                finishPaste()
                return
            case .image:
                clipboardManager.pasteItem(item)
                closeWindow()
                return
            case .text, .code:
                break
            }
        }
        clipboardManager.pasteItem(item)   // writes the right type back + guards re-capture
        finishPaste()
    }

    /// Paste a single member of an expanded multi-file group.
    private func commitPath(_ path: String) {
        clipboardManager.pasteSubPath(path)
        finishPaste()
    }

    /// Close the panel, then auto-paste the clipboard into the app we captured.
    private func finishPaste() {
        closeWindow()
        let target = capturedApp
        let isSelf = target?.processIdentifier == NSRunningApplication.current.processIdentifier
        if autoPasteEnabled, AutoPaste.isTrusted, let target, !isSelf {
            AutoPaste.paste(into: target)
        }
    }

    /// Whether the app we'll paste into is a terminal emulator.
    private var capturedIsTerminal: Bool {
        guard let name = capturedApp?.localizedName else { return false }
        return ClipboardItemRow.isTerminalApp(name)
    }

    /// Escape a path for a shell prompt the way dragging a file into Terminal does:
    /// leave normal path characters bare and backslash-escape only what the shell
    /// treats specially (spaces, quotes, globs, …). No wrapping quotes.
    private static func shellEscape(_ path: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+,@%=:")
        var out = ""
        for ch in path {
            if !safe.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// Borderless panels can't become key by default — override so keyboard input
/// (arrows / Enter via the local monitor) works without a title bar.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

