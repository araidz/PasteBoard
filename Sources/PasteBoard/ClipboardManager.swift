import Cocoa
import CryptoKit
import ImageIO
import SwiftUI

// App-internal notifications: a capture happened (menu-bar icon flash), the
// panel became visible, and the user pressed "/" to focus the search field.
extension Notification.Name {
    static let clipboardDidCapture = Notification.Name("clipboardDidCapture")
    static let panelDidShow = Notification.Name("panelDidShow")
    static let focusSearchRequested = Notification.Name("focusSearchRequested")
}

enum ClipboardItemType: String, Codable {
    case text
    case code
    case image
    case file
    case folder
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let type: ClipboardItemType
    let textContent: String?
    let imagePath: String?
    let filePaths: [String]?
    let timestamp: Date
    let sourceApp: String?
    var pinned: Bool = false

    var displayText: String {
        switch type {
        case .text, .code:
            return textContent ?? ""
        case .image:
            return "[Image]"
        case .file, .folder:
            if let paths = filePaths {
                let names = paths.map { ($0 as NSString).lastPathComponent }
                return names.joined(separator: ", ")
            }
            return type == .folder ? "[Folder]" : "[File]"
        }
    }

    var previewText: String {
        let text = displayText
        if text.count > 80 {
            return String(text.prefix(80)) + "..."
        }
        return text
    }

    /// A copy containing more than one file/folder path — rendered as an
    /// expandable group whose members can be pasted individually.
    var isGroup: Bool { (filePaths?.count ?? 0) > 1 }
}

// Custom decoding so histories written before `pinned` existed still load.
// Lives in an extension so the memberwise init stays compiler-synthesized.
extension ClipboardItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(ClipboardItemType.self, forKey: .type)
        textContent = try c.decodeIfPresent(String.self, forKey: .textContent)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

class ClipboardManager: ObservableObject {
    @Published var items: [ClipboardItem] = [] {
        didSet { cachedOrdered = nil; cachedFiltered = nil }
    }
    @Published var searchText: String = "" {
        didSet {
            cachedFiltered = nil
            // A filtered-out row must not stay selected — Enter would paste something
            // not on screen. Drop the highlight; Enter then falls back to the first match.
            if let id = selectedItemID, !filteredItems.contains(where: { $0.id == id }) {
                selectedItemID = nil
            }
        }
    }
    // Currently highlighted row, driven by keyboard navigation / clicks.
    @Published var selectedItemID: UUID?
    // Whether the full-content preview overlay is showing (space / ⌘Y). Tracks
    // selectedItemID live, so arrow keys keep updating it while it's open.
    @Published var isPreviewing: Bool = false
    // Mirrors the search field's focus state (set from HistoryView) so the
    // key monitor knows whether space/"/" should act as shortcuts or as text.
    @Published var isSearchFocused: Bool = false
    var isCaptureEnabled: Bool { historyKey != nil }

    private var lastChangeCount: Int = 0
    // Rolling-window size for unpinned items, user-adjustable from the menu and
    // persisted across launches. Changing it re-trims immediately.
    @Published private var storedMaxItems: Int
    var maxItems: Int {
        get { storedMaxItems }
        set {
            let value = Self.validatedMaxItems(newValue)
            guard value != storedMaxItems else { return }
            storedMaxItems = value
            defaults.set(value, forKey: "maxItems")
            trimUnpinned()
            saveItems()
        }
    }
    private static let searchHaystackCap = 16_384
    // Maximum size in bytes for a single clipboard item. Items exceeding this
    // are silently skipped to prevent memory/disk bloat from huge images.
    // Defaults-tunable only (no UI) — plain var, nothing observes it.
    var maxItemSizeBytes: Int {
        didSet {
            guard maxItemSizeBytes != oldValue else { return }
            defaults.set(maxItemSizeBytes, forKey: "maxItemSizeBytes")
        }
    }
    private let defaults: UserDefaults
    private let storageURL: URL          // unpinned history
    private let pinnedStorageURL: URL    // pinned items, persisted separately
    private let imageStorageURL: URL
    private var historyKey: SymmetricKey?
    // All disk writes/deletions run here so pin/delete update the UI instantly.
    private let ioQueue = DispatchQueue(label: "com.local.pasteboard.io", qos: .utility)
    // Coalesces rapid mutations (e.g. repeated pin toggles) into a single write.
    // Managed exclusively on ioQueue to avoid cross-thread races.
    private var pendingSave: DispatchWorkItem?
    private static let saveDebounce: TimeInterval = 0.4

    // Memoized derived lists — invalidated by the didSet hooks above so repeated
    // accesses within one render don't redo the ordering/filtering work.
    private var cachedOrdered: [ClipboardItem]?
    private var cachedFiltered: [ClipboardItem]?

    private func removeFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let imageDirectory = imageStorageURL.standardizedFileURL.resolvingSymlinksInPath()
        ioQueue.async {
            for path in paths {
                let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard file.deletingLastPathComponent() == imageDirectory else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // Pinned items always float to the top, newest-first within each group.
    var orderedItems: [ClipboardItem] {
        if let cachedOrdered { return cachedOrdered }
        let pinned = items.filter { $0.pinned }.sorted { $0.timestamp > $1.timestamp }
        let rest = items.filter { !$0.pinned }
        let result = pinned + rest
        cachedOrdered = result
        return result
    }

    var filteredItems: [ClipboardItem] {
        if let cachedFiltered { return cachedFiltered }
        let base = orderedItems
        let result: [ClipboardItem]
        if searchText.isEmpty {
            result = base
        } else {
            result = base.filter { item in
                // ponytail: cap the haystack so a multi-MB text item can't stall
                // typing — raise searchHaystackCap if deep-content search matters.
                item.displayText.prefix(Self.searchHaystackCap).localizedCaseInsensitiveContains(searchText)
                    || item.sourceApp?.localizedCaseInsensitiveContains(searchText) == true
                    || item.filePaths?.contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) == true
                    || item.type.rawValue.localizedCaseInsensitiveContains(searchText)
            }
        }
        cachedFiltered = result
        return result
    }

    /// `baseDirectory` lets tests redirect storage away from Application Support.
    init(
        baseDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        keyProvider: () throws -> SymmetricKey = {
            try EncryptedStore.persistentKey(service: Bundle.main.bundleIdentifier == "com.local.pasteboard.test"
                ? "com.local.pasteboard.test.historykey" : "com.local.pasteboard.historykey")
        }
    ) {
        self.defaults = defaults
        storedMaxItems = Self.validatedMaxItems((defaults.object(forKey: "maxItems") as? Int) ?? 200)
        maxItemSizeBytes = (defaults.object(forKey: "maxItemSizeBytes") as? Int) ?? 10_000_000

        let appDir: URL
        if let baseDirectory {
            appDir = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            // App-support dir for history + images. The shared bundle id keeps the
            // Accessibility grant across updates.
            appDir = appSupport.appendingPathComponent(
                Bundle.main.bundleIdentifier == "com.local.pasteboard.test" ? "PasteBoard-Test" : "PasteBoard"
            )
        }
        imageStorageURL = appDir.appendingPathComponent("Images")
        storageURL = appDir.appendingPathComponent("history.json")
        pinnedStorageURL = appDir.appendingPathComponent("pinned.json")

        // Create directories
        try? FileManager.default.createDirectory(at: imageStorageURL, withIntermediateDirectories: true)

        do {
            historyKey = try keyProvider()
        } catch {
            NSLog("PasteBoard: history key unavailable; capture disabled to preserve existing history — \(error)")
            historyKey = nil
        }

        if historyKey != nil {
            if loadItems() {
                cleanupOrphanedImages()
            } else {
                // Never overwrite or clean up data that failed authentication/loading.
                historyKey = nil
            }
        }
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private static let ignoredPasteboardTypes = Set([
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    ])

    static func shouldIgnore(types: [NSPasteboard.PasteboardType]?) -> Bool {
        guard let types else { return false }
        return !ignoredPasteboardTypes.isDisjoint(with: types)
    }

    func checkForChanges() {
        guard historyKey != nil else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !Self.shouldIgnore(types: pasteboard.types) else { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Check for files / directories first. The on-disk stat that classifies
        // file vs. folder runs off the main thread so a large copy can't stall the UI.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.path }
            ioQueue.async { [weak self] in
                guard let self else { return }
                let item = ClipboardItem(
                    id: UUID(),
                    type: Self.fileType(forPaths: paths),
                    textContent: nil,
                    imagePath: nil,
                    filePaths: paths,
                    timestamp: Date(),
                    sourceApp: sourceApp
                )
                self.addItem(item)
            }
            return
        }

        // Check for images. Short-circuit on pasteboard.types to avoid
        // decoding NSImage on the main thread when there's no image.
        if pasteboard.types?.contains(.tiff) == true || pasteboard.types?.contains(.png) == true {
            let maxSize = maxItemSizeBytes
            let pngSource = pasteboard.data(forType: .png)
            guard let imageData = pngSource ?? pasteboard.data(forType: .tiff) else { return }
            guard imageData.count <= maxSize else { return }
            ioQueue.async { [weak self] in
                guard let self else { return }
                guard Self.imageDimensionsAreSafe(imageData) else { return }
                // ponytail: PNG passes through untouched; only TIFF-only sources
                // re-encode (via NSBitmapImageRep directly — no NSImage roundtrip).
                let pngData: Data
                if pngSource != nil {
                    pngData = imageData
                } else {
                    guard let bitmap = NSBitmapImageRep(data: imageData),
                          let converted = bitmap.representation(using: .png, properties: [:]) else { return }
                    pngData = converted
                }
                // Skip oversized images to prevent memory/disk bloat.
                guard pngData.count <= maxSize else { return }
                // Content-addressed filename: identical image bytes map to the same
                // path, so the path-based dedup in insert() collapses repeat copies
                // (and the file write below becomes a no-op).
                let imageID = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
                let imagePath = self.imageStorageURL.appendingPathComponent("\(imageID).png")
                if !FileManager.default.fileExists(atPath: imagePath.path) {
                    do {
                        try pngData.write(to: imagePath)
                    } catch {
                        NSLog("PasteBoard: failed to write captured image — \(error.localizedDescription)")
                        return
                    }
                }
                let item = ClipboardItem(
                    id: UUID(),
                    type: .image,
                    textContent: nil,
                    imagePath: imagePath.path,
                    filePaths: nil,
                    timestamp: Date(),
                    sourceApp: sourceApp
                )
                self.addItem(item)
            }
            return
        }

        // Check for text. Read the string reference on the main thread (fast —
        // just a pasteboard pointer), then do classification + size check off-main.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let maxSize = maxItemSizeBytes
            ioQueue.async { [weak self] in
                guard let self else { return }
                // Skip oversized text to prevent memory bloat.
                guard text.utf8.count <= maxSize else { return }
                let item = ClipboardItem(
                    id: UUID(),
                    type: Self.looksLikeCode(text) ? .code : .text,
                    textContent: text,
                    imagePath: nil,
                    filePaths: nil,
                    timestamp: Date(),
                    sourceApp: sourceApp
                )
                self.addItem(item)
            }
        }
    }

    // MARK: - Classification (pure, internal so tests can exercise them)

    private static let maxImageDecodedPixelCount = 40_000_000

    static func imageDimensionsAreSafe(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxImageDecodedPixelCount / height
    }

    static func imageDimensionsAreSafe(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return false }
        var totalPixels = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  imageDimensionsAreSafe(width: width, height: height) else { return false }
            let pixels = width * height
            guard pixels <= maxImageDecodedPixelCount - totalPixels else { return false }
            totalPixels += pixels
        }
        return true
    }

    static func validatedMaxItems(_ value: Int) -> Int { min(max(value, 1), 1_000) }

    /// Classify copied file URLs: a copy made entirely of directories is a folder.
    static func fileType(forPaths paths: [String]) -> ClipboardItemType {
        let allDirectories = !paths.isEmpty && paths.allSatisfy { path in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }
        return allDirectories ? .folder : .file
    }

    /// Heuristic: does this text read like a code snippet rather than prose?
    private static let codeChars = Set("{}();[]<>=+*/&|")
    static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return false }

        var score = 0

        let keywords = [
            "func ", "def ", "class ", "struct ", "enum ", "import ", "#include",
            "function ", "const ", "let ", "var ", "return ", "public ", "private ",
            "void ", "static ", "=> ", "println", "console.log", "System.out",
            "<?php", "fn ", "package ", "namespace ", "#!/"
        ]
        for kw in keywords where trimmed.contains(kw) { score += 1 }

        // Density of punctuation that is common in code but rare in prose.
        var codeCharCount = 0
        for ch in trimmed { if codeChars.contains(ch) { codeCharCount += 1 } }
        if Double(codeCharCount) / Double(trimmed.count) > 0.06 { score += 1 }

        if trimmed.contains("{") && trimmed.contains("}") { score += 1 }
        if trimmed.contains(";") { score += 1 }

        // ponytail: zero-alloc scan — avoids components(separatedBy:) allocation
        let hasNewline = trimmed.contains("\n")
        let hasIndentedLine = hasNewline && (trimmed.contains("\n    ") || trimmed.contains("\n\t"))
        if hasIndentedLine { score += 1 }

        return score >= 2
    }

    // MARK: - Mutation

    private func addItem(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            guard self.insert(item) else { return }
            // NOTE: reconstructed — fires the blink in AppDelegate on capture.
            NotificationCenter.default.post(name: .clipboardDidCapture, object: nil)
        }
    }

    /// Synchronous insertion core: de-duplicates, then enforces the window.
    /// Internal so the test target can drive history without the pasteboard.
    /// Returns false when the item repeats the newest entry — apps that re-assert
    /// the clipboard on focus would otherwise flash the icon and rewrite history.
    @discardableResult
    func insert(_ item: ClipboardItem) -> Bool {
        if let top = items.first, isContentDuplicate(top, item) { return false }
        var newItem = item
        // If the same content already exists, drop the older copy and keep the
        // newest one at the top — carrying any pin forward so it isn't lost.
        if let dupIndex = items.firstIndex(where: { isContentDuplicate($0, newItem) }) {
            let dup = items[dupIndex]
            if dup.pinned { newItem.pinned = true }
            items.remove(at: dupIndex)
        }
        items.insert(newItem, at: 0)
        trimUnpinned()
        saveItems()
        return true
    }

    private func isContentDuplicate(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        switch (a.type, b.type) {
        case (.text, .text), (.text, .code), (.code, .text), (.code, .code):
            return a.textContent != nil && a.textContent == b.textContent
        case (.file, .file), (.folder, .folder), (.file, .folder), (.folder, .file):
            return a.filePaths != nil && a.filePaths == b.filePaths
        case (.image, .image):
            // Dedup by file path — same path means same captured image.
            if let pa = a.imagePath, let pb = b.imagePath { return pa == pb }
            // Fallback: if either has no path (shouldn't happen), skip dedup.
            return false
        default:
            return false
        }
    }

    // ponytail: shared partition avoids repeating the same filter over the full array
    private func partitioned() -> (pinned: [ClipboardItem], unpinned: [ClipboardItem]) {
        var p: [ClipboardItem] = [], u: [ClipboardItem] = []
        for item in items { if item.pinned { p.append(item) } else { u.append(item) } }
        return (p, u)
    }

    /// Enforce the 200-item window over unpinned items, leaving pinned ones untouched.
    private func trimUnpinned() {
        let (_, unpinned) = partitioned()
        let keep = Self.validatedMaxItems(maxItems)
        guard unpinned.count > keep else { return }
        let overflow = unpinned.suffix(from: keep) // oldest unpinned
        let removeIDs = Set(overflow.map { $0.id })
        removeFiles(overflow.compactMap { $0.imagePath })
        items.removeAll { removeIDs.contains($0.id) }
    }

    @discardableResult
    func pasteItem(_ item: ClipboardItem, to pasteboard: NSPasteboard = .general) -> Bool {
        let written: Bool
        switch item.type {
        case .text, .code:
            guard let text = item.textContent else { return false }
            pasteboard.clearContents()
            written = pasteboard.setString(text, forType: .string)
        case .image:
            guard let path = item.imagePath, let image = NSImage(contentsOfFile: path) else { return false }
            pasteboard.clearContents()
            written = pasteboard.writeObjects([image])
        case .file, .folder:
            guard let paths = item.filePaths, !paths.isEmpty,
                  paths.allSatisfy(FileManager.default.fileExists(atPath:)) else { return false }
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.clearContents()
            written = pasteboard.writeObjects(urls)
        }

        guard written else { return false }
        // Update the change count so we don't re-capture what we just pasted
        if pasteboard == .general { lastChangeCount = pasteboard.changeCount }
        return true
    }

    /// Paste a single member of a multi-file group (one file URL) — rides
    /// `pasteItem`'s file branch (existence check, write, re-capture guard).
    @discardableResult
    func pasteSubPath(_ path: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteItem(ClipboardItem(id: UUID(), type: .file, textContent: nil, imagePath: nil,
                                filePaths: [path], timestamp: Date(), sourceApp: nil), to: pasteboard)
    }

    /// Put plain text on the clipboard — used to paste a file's path into a terminal,
    /// which can't accept a file-url. Guards re-capture like the other paste methods.
    @discardableResult
    func pasteText(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        if pasteboard == .general { lastChangeCount = pasteboard.changeCount }
        return true
    }

    /// Toggle the pinned state of an item, then re-persist.
    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        saveItems()
    }

    func deleteItem(_ item: ClipboardItem) {
        // Pinned items can't be accidentally deleted — unpin first.
        guard !item.pinned else { return }
        // Move the highlight to the row that slides up into its place (or the new last
        // row if it was at the end) so the selection follows the deletion.
        if selectedItemID == item.id {
            let list = filteredItems
            if let idx = list.firstIndex(where: { $0.id == item.id }) {
                let next = idx + 1 < list.count ? list[idx + 1] : (idx > 0 ? list[idx - 1] : nil)
                selectedItemID = next?.id
            } else {
                selectedItemID = nil
            }
        }
        items.removeAll { $0.id == item.id }   // instant UI update
        if let p = item.imagePath { removeFiles([p]) }
        saveItems()
    }

    func clearAll() {
        // Preserve pinned items; only clear the rolling history.
        let unpinned = items.filter { !$0.pinned }
        let imagePaths = unpinned.compactMap { $0.imagePath }
        items.removeAll { !$0.pinned }         // instant UI update
        removeFiles(imagePaths)
        saveItems()
    }

    // MARK: - Keyboard navigation

    var selectedItem: ClipboardItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    func togglePreview() {
        if isPreviewing {
            isPreviewing = false
        } else if let item = selectedItem ?? filteredItems.first {
            selectedItemID = item.id
            isPreviewing = true
        }
    }

    /// Move the highlighted row through the currently displayed list.
    func moveSelection(by delta: Int) {
        let list = filteredItems
        guard !list.isEmpty else {
            selectedItemID = nil
            return
        }
        if let currentIndex = list.firstIndex(where: { $0.id == selectedItemID }) {
            // Wrap around: past the last row jumps to the first, and vice-versa.
            // ponytail: double-mod handles negative delta wrapping
            let count = list.count
            let newIndex = ((currentIndex + delta) % count + count) % count
            selectedItemID = list[newIndex].id
        } else {
            // Nothing selected yet: enter from the appropriate end.
            selectedItemID = (delta >= 0 ? list.first : list.last)?.id
        }
    }

    /// Remove image files on disk that aren't referenced by any history item.
    /// Called once at launch to prevent slow leakage from failed deletions.
    private func cleanupOrphanedImages() {
        // ponytail: standardised paths avoid /var vs /private/var symlink mismatches
        let referencedPaths = Set(items.compactMap {
            $0.imagePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        })
        ioQueue.async { [weak self] in
            guard let self else { return }
            let imageDir = self.imageStorageURL.standardizedFileURL
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: imageDir, includingPropertiesForKeys: nil
            ) else { return }
            for file in files {
                if !referencedPaths.contains(file.standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Persistence

    /// Encode + encrypt + write both files. Runs on ioQueue; strong `self` is
    /// deliberate so an in-flight write completes even during teardown.
    private func writeAll(pinned: [ClipboardItem], unpinned: [ClipboardItem], key: SymmetricKey) {
        do {
            try EncryptedStore.encrypt(JSONEncoder().encode(unpinned), key: key)
                .write(to: storageURL, options: .atomic)
            try EncryptedStore.encrypt(JSONEncoder().encode(pinned), key: key)
                .write(to: pinnedStorageURL, options: .atomic)
        } catch {
            NSLog("PasteBoard: failed to persist history — \(error.localizedDescription)")
        }
    }

    private func saveItems() {
        guard let historyKey else { return }
        // Snapshot on the main thread, then encode + write off the main thread.
        // A burst of mutations (rapid pin toggles, a flurry of captures) collapses
        // into a single write via the debounced work item.
        let (pinned, unpinned) = partitioned()
        let work = DispatchWorkItem { self.writeAll(pinned: pinned, unpinned: unpinned, key: historyKey) }
        // Manage pendingSave entirely on ioQueue to avoid cross-thread races.
        ioQueue.async {
            self.pendingSave?.cancel()
            self.pendingSave = work
            self.ioQueue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
        }
    }

    func flush() {
        guard let historyKey else { return }
        let (pinned, unpinned) = partitioned()
        ioQueue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            writeAll(pinned: pinned, unpinned: unpinned, key: historyKey)
        }
    }

    private func loadItems() -> Bool {
        func load(_ url: URL, name: String, pinned: Bool) -> [ClipboardItem]? {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            do {
                return try decodeHistory([ClipboardItem].self, from: Data(contentsOf: url)).map {
                    var item = $0; item.pinned = pinned; return item
                }
            } catch {
                NSLog("PasteBoard: \(name) unavailable; capture disabled — \(error.localizedDescription)")
                return nil
            }
        }
        guard let pinned = load(pinnedStorageURL, name: "pinned history", pinned: true),
              let unpinned = load(storageURL, name: "history", pinned: false) else { return false }
        // Keep a single recency-ordered array; `orderedItems` floats pins to the top.
        items = (pinned + unpinned).sorted { $0.timestamp > $1.timestamp }
        return true
    }

    /// Decrypts `data` (current on-disk format); falls back to plain JSON so
    /// histories written before encryption existed still load. The next save
    /// re-persists the file encrypted.
    private func decodeHistory<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let historyKey else { throw EncryptedStoreError.encryptionFailed }
        if let decrypted = try? EncryptedStore.decrypt(data, key: historyKey) {
            return try JSONDecoder().decode(type, from: decrypted)
        }
        return try JSONDecoder().decode(type, from: data)   // legacy plain JSON
    }
}
