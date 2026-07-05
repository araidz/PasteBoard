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
    @State private var image: NSImage?

    var body: some View {
        thumbnail
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, alignment: .leading)
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
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
        }
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var manager: ClipboardManager
    var onCommit: (ClipboardItem) -> Void = { _ in }
    var onCommitPath: (String) -> Void = { _ in }
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
                                    onDelete: { manager.deleteItem(item) },
                                    onTogglePin: { manager.togglePin(item) },
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
                Text("⏎ paste · ⌘1–9 quick · esc close")
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
        .onTapGesture(count: 2) { onPaste() }
        .onHover { hovered = $0 }
    }
}

/// A small icon button used for the per-row pin / delete actions, with its own
/// hover affordance so the targets feel responsive.
private struct RowActionButton: View {
    let systemName: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.primary.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct ClipboardItemRow: View, Equatable {
    let item: ClipboardItem
    let isSelected: Bool
    // 1–9 for the first nine rows → shows a ⌘N quick-paste hint. nil otherwise.
    var shortcutIndex: Int? = nil
    let onPaste: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    // Paste a single member of a multi-file group. Unused for non-group rows.
    var onPastePath: (String) -> Void = { _ in }

    // Only the data that affects rendering matters — the closures are recreated on
    // every parent render but don't change what's drawn. Comparing just `item` and
    // `isSelected` lets SwiftUI skip re-rendering every visible row when one pin /
    // delete mutates the list; only the row that actually changed re-renders.
    static func == (lhs: ClipboardItemRow, rhs: ClipboardItemRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.shortcutIndex == rhs.shortcutIndex
    }

    // Hover is local so hovering one row never re-renders the rest of the list.
    @State private var isHovered = false
    // Multi-file groups can be expanded to reveal their members.
    @State private var expanded = false
    private var isHighlighted: Bool { isHovered || isSelected }

    // On an accent-highlighted row, text/icons flip to white like a native menu item.
    private var contentColor: Color { isHighlighted ? .white : .primary }
    private var secondaryColor: Color { isHighlighted ? Color.white.opacity(0.85) : .secondary }

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
            actionColumn

            // Type icon — reflects the kind of content / file.
            Image(systemName: iconName)
                .frame(width: 22)
                .foregroundColor(secondaryColor)

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
        // Double-click pastes and closes. A single click does nothing — only
        // hover changes the highlight.
        .onTapGesture(count: 2) {
            onPaste()
        }
        .onHover { hovering in
            isHovered = hovering
        }
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
            actionColumn

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

            Image(systemName: item.type == .folder ? "folder" : "doc.on.doc")
                .frame(width: 22)
                .foregroundColor(secondaryColor)

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
        // Double-click the header pastes the whole group.
        .onTapGesture(count: 2) {
            onPaste()
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Shared pieces

    /// Leading pin/delete column — reserved space so the row never reflows;
    /// the buttons fade in on hover and act on the whole item/group.
    private var actionColumn: some View {
        VStack(spacing: 6) {
            RowActionButton(
                systemName: item.pinned ? "pin.slash" : "pin",
                tint: isHighlighted ? .white : .secondary,
                help: item.pinned ? "Unpin this item" : "Pin this item",
                action: onTogglePin
            )
            if !item.pinned {
                RowActionButton(
                    systemName: "xmark",
                    tint: isHighlighted ? .white : .secondary,
                    help: "Delete this item from history",
                    action: onDelete
                )
            }
        }
        .frame(width: 18)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
    }

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
        if Self.looksLikeEmail(text) { return "envelope" }
        return item.type == .code ? "chevron.left.forwardslash.chevron.right" : "doc.text"
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

    @ViewBuilder
    var contentPreview: some View {
        // A photo (copied image or a single image file) previews as a thumbnail
        // instead of showing its filename. The thumbnail loads asynchronously.
        if let path = thumbnailPath {
            ThumbnailView(path: path)
        } else {
            switch item.type {
            case .text:
                Text(item.previewText)
                    .font(.system(size: 12))
                    .foregroundColor(contentColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .code:
                // Show the snippet in its source format: monospaced, preserving
                // indentation and line breaks (a few lines as a preview).
                Text(codePreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(contentColor)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .image:
                Text("[Image]")
                    .font(.system(size: 12))
                    .foregroundColor(secondaryColor)
            case .file, .folder:
                // Show the filename prominently rather than the full path.
                Text(item.previewText)
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                    .foregroundColor(contentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
