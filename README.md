# PasteBoard

A lightweight clipboard history manager for macOS that lives in your menu bar. Copy anything — text, code, images, files, or folders — press **⌥⌘V**, and paste it straight back into whatever app you're in.

## Features

- ⌨️ **⌥⌘V anywhere** — a global hotkey opens your history over any app, search focused
- ⚡ **Auto-paste** — pick an item and it lands in the app you were typing in (needs Accessibility; falls back to copy-only)
- 🔢 **⌘1–9 quick paste** — grab the top nine items by number
- 📋 **History** for text, code, images, and files/folders
- 🔍 **Instant search** across everything you've copied
- 📌 **Pin** the items you reuse so they stay at the top
- 🖼️ **Image thumbnails** generated efficiently in the background
- 🚀 **Launch at login** (optional)
- 🪶 Native, lightweight menu bar app — no Electron, no clutter

## How it works

1. Copy anything with ⌘C — PasteBoard records it automatically.
2. Press **⌥⌘V** — your history appears at the pointer, search ready.
3. Pick with a double-click, **⏎**, or **⌘1–9** — it pastes into the app you were in.

Clicking the menu-bar icon opens a menu of options: launch at login, paste-directly toggle, Accessibility, history limit, and quit.

## Requirements

- macOS 13 (Ventura) or later

## Install

### Homebrew (recommended)

```bash
brew install --cask araidz/tap/pasteboard
```

### Direct download

1. Grab **`PasteBoard.dmg`** from the [Releases](https://github.com/araidz/PasteBoard/releases/latest) page.
2. Open it and drag **PasteBoard** into **Applications**.

Because this is a free, un-notarized app, macOS blocks it on first launch. Right-click **PasteBoard** → **Open** → **Open**. If you see *"damaged and can't be opened"*:

```bash
xattr -dr com.apple.quarantine /Applications/PasteBoard.app
```

### Enable auto-paste

To let PasteBoard paste directly into other apps, grant it Accessibility: **System Settings → Privacy & Security → Accessibility**, or use the menu's **Enable Accessibility**. Without it, picking a clip still copies — press ⌘V yourself.

## Build from source

```bash
git clone https://github.com/araidz/PasteBoard.git
cd PasteBoard
swift build -c release      # or: open Package.swift in Xcode
swift test                  # run the tests
./build-release.sh          # package an .app + .dmg into dist/
```

`build-release.sh` ad-hoc signs by default. Run `./make-signing-cert.sh` once to sign with a stable self-signed certificate, so the Accessibility grant persists across updates.

## License

See [LICENSE](LICENSE).
