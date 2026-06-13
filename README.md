# PasteBoard

A lightweight clipboard history manager for macOS that lives in your menu bar. Copy anything — text, code, images, files, or folders — and PasteBoard keeps a searchable history you can paste back at any time.

## Features

- 📋 **Clipboard history** for text, code, images, and files/folders
- 🔍 **Instant search** across everything you've copied
- 📌 **Pin** the items you reuse most so they stay at the top
- 🖼️ **Image thumbnails** generated efficiently in the background
- ⌨️ **Keyboard-driven** floating panel — open, search, and paste without the mouse
- 🚀 **Launch at login** (optional)
- 🪶 Native, lightweight menu bar app — no Electron, no clutter

## Requirements

- macOS 13 (Ventura) or later

## Install (for everyone)

1. Go to the [**Releases**](https://github.com/araidz/PasteBoard/releases/latest) page.
2. Download **`PasteBoard.dmg`**.
3. Open the `.dmg` and drag **PasteBoard** into your **Applications** folder.

### First launch

Because this is a free app that isn't signed with a paid Apple Developer certificate, macOS will block it the first time. This is expected. To open it:

1. **Right-click** (or Control-click) **PasteBoard** in Applications and choose **Open**.
2. In the dialog that appears, click **Open** again.

You only need to do this once. After that it opens normally and appears in your menu bar.

> If you still see *"PasteBoard is damaged and can't be opened"*, run this in Terminal to remove the quarantine flag:
> ```bash
> xattr -dr com.apple.quarantine /Applications/PasteBoard.app
> ```

## Build from source (for developers)

```bash
git clone https://github.com/araidz/PasteBoard.git
cd PasteBoard
swift build -c release
```

Or open the package in Xcode and run it:

```bash
open Package.swift
```

## License

See [LICENSE](LICENSE).
