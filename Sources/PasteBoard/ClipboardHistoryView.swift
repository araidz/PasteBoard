import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Caches downsampled thumbnails so image rows don't re-read/decode the PNG from
/// disk on every render. Thumbnails are generated off the main thread and stored
/// at display scale (not full resolution) so a long history of large images can't
/// pin hundreds of MB resident.
enum ThumbnailCache {
    // Generated thumbnails are square-ish and small; this is the largest edge
    // length we ask ImageIO to produce (the row renders them at 40pt @2x).
    static let maxPixelSize = 120

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        c.totalCostLimit = 24 * 1024 * 1024   // ~24 MB of decoded thumbnails
        return c
    }()
    private static let queue = DispatchQueue(
        label: "com.local.pasteboard.thumbnails", qos: .userInitiated, attributes: .concurrent
    )

    /// Deliver a thumbnail for `path`. If it's already cached the completion runs
    /// synchronously on the calling thread; otherwise it's decoded off-main and the
    /// completion is invoked on the main thread.
    static func load(path: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: path as NSString) {
            completion(cached)
            return
        }
        queue.async {
            let image = downsample(path: path)
            if let image {
                let rep = image.representations.first
                let cost = (rep?.pixelsWide ?? maxPixelSize) * (rep?.pixelsHigh ?? maxPixelSize) * 4
                cache.setObject(image, forKey: path as NSString, cost: cost)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func downsample(path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Loads its thumbnail asynchronously, showing a neutral placeholder until the
/// downsampled image is ready so scrolling never blocks on a disk decode.
private struct ThumbnailView: View {
    let path: String
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        thumbnail
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onAppear {
                guard image == nil else { return }
                ThumbnailCache.load(path: path) { loaded in image = loaded }
            }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
        }
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var manager: ClipboardManager
    var onCommit: (ClipboardItem) -> Void = { _ in }
    var onCommitPath: (String) -> Void = { _ in }
    // Settings actions, surfaced in the header's gear menu (no more menu-bar menu).
    var onToggleLaunchAtLogin: () -> Void = {}
    var isLaunchAtLogin: () -> Bool = { false }
    var onToggleAutoPaste: () -> Void = {}
    var isAutoPasteOn: () -> Bool = { true }
    var onEnableAccessibility: () -> Void = {}
    var isTrusted: () -> Bool = { false }
    var onQuit: () -> Void = {}
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("PasteBoard")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                // Count badge — reflects the list shown (matches an active search).
                Text("\(manager.filteredItems.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Menu {
                    Button((isLaunchAtLogin() ? "✓ " : "") + "Launch at Login", action: onToggleLaunchAtLogin)
                    Button((isAutoPasteOn() ? "✓ " : "") + "Paste Directly Into App", action: onToggleAutoPaste)
                    if isTrusted() {
                        Text("Accessibility Enabled")
                    } else {
                        Button("Enable Accessibility…", action: onEnableAccessibility)
                    }
                    Menu("History Limit") {
                        ForEach([50, 100, 200, 500, 1000], id: \.self) { n in
                            Button((manager.maxItems == n ? "✓ " : "") + "\(n) items") { manager.maxItems = n }
                        }
                    }
                    Divider()
                    Button("Quit PasteBoard", action: onQuit)
                } label: {
                    Image(systemName: "gearshape").foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Search — always visible; focused automatically when the panel opens.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Search...", text: $manager.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !manager.searchText.isEmpty {
                    Button(action: { manager.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Clipboard items list
            if manager.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clipboard")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(manager.searchText.isEmpty ? "No items yet" : "No matches")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(manager.searchText.isEmpty ? "Copy something to get started" : "Try a different search")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if manager.searchText.isEmpty {
                        Text("Press ⌥⌘V anywhere to open")
                            .font(.caption2)
                            .foregroundColor(Color.secondary.opacity(0.7))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(manager.filteredItems.enumerated()), id: \.element.id) { index, item in
                                if let label = sectionLabel(at: index) {
                                    sectionHeader(label)
                                }
                                ClipboardItemRow(
                                    item: item,
                                    isSelected: manager.selectedItemID == item.id,
                                    shortcutIndex: index < 9 ? index + 1 : nil,
                                    onPaste: { onCommit(item) },
                                    onSelect: { manager.selectedItemID = item.id },
                                    onPastePath: { path in onCommitPath(path) }
                                )
                                .equatable()
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 4)
                        // Small trailing inset so the overlay scroller floats clear of the text.
                        .padding(.trailing, 4)
                        // Force a thin, auto-hiding overlay scroller.
                        .background(ScrollerConfigurator())
                    }
                    // Keep the keyboard-selected row visible as it moves.
                    .onChange(of: manager.selectedItemID) { newValue in
                        guard let id = newValue else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            Divider()
            // Footer — keyboard hints + Clear all (the one history action kept here).
            HStack(spacing: 0) {
                Text("⏎ paste · ⌘P pin · ⌘⌫ delete")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { manager.clearAll() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                        Text("Clear all")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear all (keeps pinned)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        // No fixed size — the window drives the size; these are sensible minimums.
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        // Render on the same surface the system uses for menus so the panel matches
        // their shade and translucency (Liquid Glass on macOS 26+, the classic menu
        // material on older systems). See MenuSurface.
        .modifier(MenuSurface())
        .onReceive(NotificationCenter.default.publisher(for: .panelDidShow)) { _ in
            searchFocused = true
        }
    }

    // Section label for the row at `index`: "Pinned" atop pinned items, "Recent"
    // at the first unpinned item. nil elsewhere (no header).
    private func sectionLabel(at index: Int) -> String? {
        let items = manager.filteredItems
        if index == 0 { return items[index].pinned ? "Pinned" : "Recent" }
        if !items[index].pinned && items[index - 1].pinned { return "Recent" }
        return nil
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

}

/// The panel's background surface, matched to whatever the OS uses for real menus.
///
/// On macOS 26+ the panel is hosted inside an `NSGlassEffectView` (see AppDelegate),
/// which provides the genuine Liquid Glass material, rounded corners, and shadow as
/// a single unit — so here we add nothing and just let the content draw on it.
/// Earlier releases that predate Liquid Glass fall back to the classic `.menu`
/// vibrancy material with a clip and a hairline border.
private struct MenuSurface: ViewModifier {
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 13, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content
                .background(VisualEffectView(material: .menu))
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

/// Native translucent menu material so the panel matches system menus
/// (Wi-Fi / Control Center) instead of a flat, opaque background. Used as the
/// pre-Liquid-Glass fallback in MenuSurface.
private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // Always render the active (not the dimmed inactive) material, like an open
        // menu. Left un-emphasized so it matches a stock menu's exact shade.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Forces the enclosing NSScrollView to use a thin, auto-hiding overlay scroller
/// so the scroll bar no longer overlaps the row controls.
private struct ScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.verticalScroller?.controlSize = .small
            scrollView.scrollerInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Memoizes the icon for an extension — the lookup (especially the UTType
// fallback) is pure in `ext`, and extensions repeat heavily across a history.
// Touched only from the main thread during view rendering.
private var fileIconCache: [String: String] = [:]

/// SF Symbol for a file, chosen by its extension. Shared by single rows and
/// the members of an expanded multi-file group. Generously categorized.
func fileIconName(forPath path: String?) -> String {
    let ext = (path.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
    if let cached = fileIconCache[ext] { return cached }
    let name = resolveFileIconName(forExtension: ext)
    fileIconCache[ext] = name
    return name
}

/// Uncached resolution of an extension to an SF Symbol name.
private func resolveFileIconName(forExtension ext: String) -> String {
    switch ext {
    // Archives / packages
    case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "pkg", "xip", "deb":
        return "doc.zipper"
    // Disk images
    case "dmg", "iso", "img", "sparseimage", "sparsebundle":
        return "opticaldiscdrive"
    // Images
    case "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg", "ico":
        return "photo"
    // PDF
    case "pdf":
        return "doc.richtext"
    // Word-processing / rich documents
    case "doc", "docx", "pages", "rtf", "rtfd", "odt":
        return "doc.text"
    // Plain text / notes / markdown
    case "txt", "text", "md", "markdown", "log", "rst":
        return "doc.plaintext"
    // Spreadsheets
    case "xls", "xlsx", "numbers", "csv", "tsv", "ods":
        return "tablecells"
    // Presentations
    case "ppt", "pptx", "key", "odp":
        return "rectangle.on.rectangle"
    // Audio
    case "mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "ogg", "opus", "wma", "mid", "midi":
        return "music.note"
    // Video
    case "mp4", "mov", "avi", "mkv", "m4v", "webm", "wmv", "flv", "mpg", "mpeg", "3gp":
        return "film"
    // Source code
    case "swift", "c", "cpp", "cc", "cxx", "h", "hpp", "m", "mm", "java", "kt", "kts",
         "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "php", "cs",
         "html", "htm", "css", "scss", "sass", "sh", "bash", "zsh", "fish",
         "pl", "lua", "sql", "r", "dart", "scala", "vue", "svelte", "ex", "exs":
        return "chevron.left.forwardslash.chevron.right"
    // Structured data / config
    case "json", "xml", "yaml", "yml", "toml", "plist", "ini", "conf", "cfg", "env":
        return "curlybraces"
    // Fonts
    case "ttf", "otf", "woff", "woff2", "ttc", "eot":
        return "textformat"
    // Ebooks
    case "epub", "mobi", "azw", "azw3":
        return "book"
    // Design / graphics source
    case "psd", "ai", "sketch", "fig", "xcf", "afdesign", "afphoto", "indd":
        return "paintpalette"
    // Apps / executables
    case "app", "exe", "appimage", "msi":
        return "app"
    // Calendar / contacts
    case "ics", "ical":
        return "calendar"
    case "vcf", "vcard":
        return "person.crop.square"
    default:
        break
    }
    // Anything not in the curated list above: resolve via the system's Uniform
    // Type hierarchy so even uncommon/unknown extensions map to a sensible
    // category icon instead of a generic document.
    return systemTypeIconName(forExtension: ext)
}

/// Maps a file extension to a category icon using `UTType` conformance, so the
/// app covers essentially every registered file type. Falls back to a generic
/// document glyph only when the type is truly unknown.
private func systemTypeIconName(forExtension ext: String) -> String {
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
    // Most specific first — many types conform to broader ones (e.g. source
    // code and JSON both conform to plain text).
    if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .shellScript) {
        return "chevron.left.forwardslash.chevron.right"
    }
    if type.conforms(to: .json) || type.conforms(to: .xml) || type.conforms(to: .propertyList) {
        return "curlybraces"
    }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .movie) { return "film" }
    if type.conforms(to: .audio) { return "music.note" }
    if type.conforms(to: .audiovisualContent) { return "film" }
    if type.conforms(to: .diskImage) { return "opticaldiscdrive" }
    if type.conforms(to: .archive) { return "doc.zipper" }
    if type.conforms(to: .font) { return "textformat" }
    if type.conforms(to: .application) || type.conforms(to: .executable) || type.conforms(to: .unixExecutable) {
        return "app"
    }
    if type.conforms(to: .vCard) || type.conforms(to: .contact) { return "person.crop.square" }
    if type.conforms(to: .calendarEvent) { return "calendar" }
    if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return "doc.text" }
    if type.conforms(to: .spreadsheet) { return "tablecells" }
    if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
    if type.conforms(to: .plainText) { return "doc.plaintext" }
    if type.conforms(to: .text) { return "doc.text" }
    return "doc"
}

/// A single member of an expanded multi-file group: filename + type icon,
/// double-click pastes just that one file.
private struct GroupMemberRow: View {
    let path: String
    let onPaste: () -> Void
    @State private var hovered = false

    private var filename: String { (path as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: fileIconName(forPath: path))
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundColor(hovered ? .white : .secondary)
            Text(filename)
                .font(.system(size: 11))
                .foregroundColor(hovered ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        // Indent so members sit under the group's content, past the chevron.
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered ? Color.accentColor.opacity(0.85) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .overlay(ClickCatcher { if $0 >= 2 { onPaste() } })
        .onHover { hovered = $0 }
    }
}

/// OS-native double-click via AppKit `clickCount` (matches the user's System
/// Settings), replacing SwiftUI's `.onTapGesture(count: 2)` which caused lag and
/// flaky double-clicks. count 2 → paste; single click does nothing (highlight is
/// arrow-only). Deferred one tick so the click's mouseUp completes before the panel
/// closes (a synchronous close orphaned the mouseUp → "+" drag cursor).
private struct ClickCatcher: NSViewRepresentable {
    let onClick: (Int) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = ClickView()
        v.onClick = onClick
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickView)?.onClick = onClick
    }
    final class ClickView: NSView {
        var onClick: ((Int) -> Void)?
        override func mouseDown(with event: NSEvent) {
            let count = event.clickCount
            DispatchQueue.main.async { [weak self] in self?.onClick?(count) }
        }
    }
}

struct ClipboardItemRow: View, Equatable {
    let item: ClipboardItem
    let isSelected: Bool
    // 1–9 for the first nine rows → shows a ⌘N quick-paste hint. nil otherwise.
    var shortcutIndex: Int? = nil
    let onPaste: () -> Void
    var onSelect: () -> Void = {}
    // Paste a single member of a multi-file group. Unused for non-group rows.
    var onPastePath: (String) -> Void = { _ in }

    // Only the data that affects rendering matters — the closures are recreated on
    // every parent render but don't change what's drawn. Comparing just `item` and
    // `isSelected` lets SwiftUI skip re-rendering every visible row when one pin /
    // delete mutates the list; only the row that actually changed re-renders.
    static func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.shortcutIndex == rhs.shortcutIndex
    }

    // Multi-file groups can be expanded to reveal their members.
    @State private var expanded = false
    // Only keyboard/click selection highlights a row — never hover.
    private var isHighlighted: Bool { isSelected }

    // On an accent-highlighted row, text/icons flip to white like a native menu item.
    private var contentColor: Color { isHighlighted ? .white : .primary }
    private var secondaryColor: Color { isHighlighted ? Color.white.opacity(0.85) : .secondary }

    // Uniform size for the leading icon tile / thumbnail.
    static let iconSize: CGFloat = 28

    /// The leading tile: a thumbnail for images, a colour swatch for hex colours,
    /// otherwise a colour-coded rounded square with a category glyph.
    @ViewBuilder
    private var iconTile: some View {
        if let path = thumbnailPath {
            ThumbnailView(path: path, size: Self.iconSize)
        } else if let swatch = swatchColor {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(swatch)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.25)))
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(iconTint.gradient)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .overlay(
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                )
        }
    }

    /// Tile background colour, keyed to the content/file category.
    private var iconTint: Color {
        switch item.type {
        case .image: return Color(nsColor: .systemTeal)
        case .folder: return Color(nsColor: .systemOrange)
        case .file: return Self.tint(forSymbol: fileIconName(forPath: item.filePaths?.first))
        case .text, .code:
            if let app = item.sourceApp, Self.isTerminalApp(app) { return Color(nsColor: .systemGray) }
            let text = (item.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.looksLikeURL(text) || Self.looksLikeEmail(text) { return Color(nsColor: .systemBlue) }
            return item.type == .code ? Color(nsColor: .systemIndigo) : Color(nsColor: .systemGray)
        }
    }

    /// A lone hex-colour string renders as a colour swatch tile.
    private var swatchColor: Color? {
        guard item.type == .text || item.type == .code else { return nil }
        return Self.hexColor((item.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Code snippet preview that keeps the source's formatting (newlines and
    /// indentation), capped so very long snippets don't render huge strings.
    private var codePreview: String {
        let raw = item.textContent ?? ""
        return raw.count > 300 ? String(raw.prefix(300)) + "…" : raw
    }

    /// Path to an image we can preview as a thumbnail: the stored PNG for copied
    /// images, or the file itself when a single image file/screenshot was copied.
    private var thumbnailPath: String? {
        switch item.type {
        case .image:
            return item.imagePath
        case .file, .folder:
            // Only a lone image file previews — multi-file copies keep their list.
            guard let paths = item.filePaths, paths.count == 1, let path = paths.first else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp"]
            return imageExts.contains(ext) ? path : nil
        case .text, .code:
            return nil
        }
    }

    var body: some View {
        if item.isGroup {
            groupContainer
        } else {
            singleRow
        }
    }

    // MARK: - Single (non-group) row

    private var singleRow: some View {
        HStack(spacing: 5) {
            iconTile

            // Content preview
            VStack(alignment: .leading, spacing: 2) {
                contentPreview
                metadataLine
            }

            Spacer(minLength: 0)
            shortcutBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlightBackground)
        .contentShape(Rectangle())
        // Double-click pastes; single click does nothing (highlight via arrows only).
        .overlay(ClickCatcher { if $0 >= 2 { onPaste() } })
    }

    // MARK: - Multi-file group

    private var groupContainer: some View {
        VStack(alignment: .leading, spacing: 1) {
            groupHeader
            if expanded {
                ForEach(Array((item.filePaths ?? []).enumerated()), id: \.offset) { _, path in
                    GroupMemberRow(path: path, onPaste: { onPastePath(path) })
                }
            }
        }
    }

    private var groupHeader: some View {
        HStack(spacing: 5) {
            // Disclosure chevron — always visible; toggles the member list.
            Button(action: { withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() } }) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .frame(width: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Expand")

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .systemOrange).gradient)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .overlay(
                    Image(systemName: item.type == .folder ? "folder.fill" : "doc.on.doc.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(isHighlighted ? .white : .orange)
                    }
                    Text("\(item.filePaths?.count ?? 0) items")
                        .font(.system(size: 12))
                        .fontWeight(.medium)
                        .foregroundColor(contentColor)
                }
                // Comma-joined member names as a summary subtitle.
                Text(item.displayText)
                    .font(.system(size: 10))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
            shortcutBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlightBackground)
        .contentShape(Rectangle())
        // Double-click pastes the whole group; single click does nothing.
        .overlay(ClickCatcher { if $0 >= 2 { onPaste() } })
    }

    // MARK: - Shared pieces

    /// The ⌘1–9 quick-paste hint on the trailing edge of the first nine rows.
    @ViewBuilder
    private var shortcutBadge: some View {
        if let n = shortcutIndex {
            Text("⌘\(n)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(secondaryColor)
        }
    }

    private var highlightBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isHighlighted ? Color.accentColor : Color.clear)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var metadataLine: some View {
        if item.pinned || item.sourceApp != nil {
            HStack(spacing: 4) {
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(isHighlighted ? .white : .orange)
                }
                if let app = item.sourceApp {
                    Text(app)
                        .font(.system(size: 10))
                        .foregroundColor(secondaryColor)
                        .lineLimit(1)
                }
            }
        }
    }

    /// SF Symbol representing the kind of entry (text, code, image, or file by type).
    var iconName: String {
        switch item.type {
        case .text, .code:
            return textIcon
        case .image:
            return "photo"
        case .folder:
            return "folder"
        case .file:
            return fileIconName(forPath: item.filePaths?.first)
        }
    }

    /// Refine the glyph for textual entries: terminal output, links, and emails
    /// get their own icons; otherwise code vs. plain text.
    private var textIcon: String {
        if let app = item.sourceApp, Self.isTerminalApp(app) {
            return "terminal"
        }
        let text = (item.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeURL(text) { return "link" }
        if Self.looksLikeEmail(text) { return "envelope.fill" }
        return item.type == .code ? "chevron.left.forwardslash.chevron.right" : "text.alignleft"
    }

    /// Loose match for terminal emulators by their app name.
    static func isTerminalApp(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("term") { return true }   // Terminal, iTerm2, WezTerm, …
        return ["ghostty", "warp", "kitty", "alacritty", "hyper", "tabby", "console"]
            .contains { n.contains($0) }
    }

    /// A single-token string that reads like a web/ftp URL.
    static func looksLikeURL(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(" "), !s.contains("\n") else { return false }
        let lower = s.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("ftp://") || lower.hasPrefix("www.")
    }

    /// A single-token string that reads like an email address.
    static func looksLikeEmail(_ s: String) -> Bool {
        guard !s.contains(" "), !s.contains("\n"), s.contains("@") else { return false }
        let parts = s.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    /// A lone hex-colour string (`#RGB` / `#RRGGBB`) → its Color, for a swatch tile.
    static func hexColor(_ s: String) -> Color? {
        guard s.hasPrefix("#") else { return nil }
        let hex = s.dropFirst()
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        let full = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : String(hex)
        guard let v = UInt64(full, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }

    /// Category colour for a resolved file glyph, so file tiles are colour-coded.
    static func tint(forSymbol symbol: String) -> Color {
        switch symbol {
        case "photo": return Color(nsColor: .systemTeal)
        case "doc.richtext": return Color(nsColor: .systemRed)
        case "doc.zipper": return Color(nsColor: .systemBrown)
        case "tablecells": return Color(nsColor: .systemGreen)
        case "rectangle.on.rectangle": return Color(nsColor: .systemOrange)
        case "music.note", "paintpalette": return Color(nsColor: .systemPink)
        case "film": return Color(nsColor: .systemPurple)
        case "chevron.left.forwardslash.chevron.right", "curlybraces": return Color(nsColor: .systemIndigo)
        case "book", "textformat": return Color(nsColor: .systemBrown)
        case "app", "person.crop.square", "doc.plaintext", "doc.text": return Color(nsColor: .systemBlue)
        case "calendar": return Color(nsColor: .systemRed)
        default: return Color(nsColor: .systemGray)
        }
    }

    @ViewBuilder
    var contentPreview: some View {
        switch item.type {
        case .text:
            Text(item.previewText)
                .font(.system(size: 12))
                .foregroundColor(contentColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code:
            codeText
        case .image:
            Text("Image")
                .font(.system(size: 12))
                .foregroundColor(contentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .file, .folder:
            Text(item.previewText)
                .font(.system(size: 12))
                .fontWeight(.medium)
                .foregroundColor(contentColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Syntax-highlighted on a normal row; plain white when the row is accented
    /// (coloured tokens would fight the accent background).
    @ViewBuilder
    private var codeText: some View {
        Group {
            if isHighlighted {
                Text(codePreview).foregroundColor(.white)
            } else {
                Text(SyntaxHighlighter.highlight(codePreview))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(6)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
