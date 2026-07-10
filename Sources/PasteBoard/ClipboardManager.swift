import Cocoa
import CryptoKit
import SwiftUI

// App-internal notifications: a capture happened (menu-bar icon flash, later phase)
// and the panel became visible (focus the search field).
extension Notification.Name {
    static let clipboardDidCapture = Notification.Name("clipboardDidCapture")
    static let panelDidShow = Notification.Name("panelDidShow")
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
    var pinned: Bool

    init(
        id: UUID,
        type: ClipboardItemType,
        textContent: String?,
        imagePath: String?,
        filePaths: [String]?,
        timestamp: Date,
        sourceApp: String?,
        pinned: Bool = false
    ) {
        self.id = id
        self.type = type
        self.textContent = textContent
        self.imagePath = imagePath
        self.filePaths = filePaths
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.pinned = pinned
    }

    // Custom decoding so histories written before `pinned` existed still load.
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

    private var lastChangeCount: Int = 0
    // Rolling-window size for unpinned items, user-adjustable from the menu and
    // persisted across launches. Changing it re-trims immediately.
    @Published var maxItems: Int = (UserDefaults.standard.object(forKey: "maxItems") as? Int) ?? 200 {
        didSet {
            guard maxItems != oldValue else { return }
            UserDefaults.standard.set(maxItems, forKey: "maxItems")
            trimUnpinned()
            saveItems()
        }
    }
    private let storageURL: URL          // unpinned history
    private let pinnedStorageURL: URL    // pinned items, persisted separately
    private let imageStorageURL: URL
    private let historyKey: SymmetricKey
    // All disk writes/deletions run here so pin/delete update the UI instantly.
    private let ioQueue = DispatchQueue(label: "com.local.pasteboard.io", qos: .utility)
    // Coalesces rapid mutations (e.g. repeated pin toggles) into a single write.
    private var pendingSave: DispatchWorkItem?
    private static let saveDebounce: TimeInterval = 0.4

    // Memoized derived lists — invalidated by the didSet hooks above so repeated
    // accesses within one render don't redo the ordering/filtering work.
    private var cachedOrdered: [ClipboardItem]?
    private var cachedFiltered: [ClipboardItem]?

    private func removeFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        ioQueue.async {
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // Pinned items always float to the top, newest-first within each group.
    var orderedItems: [ClipboardItem] {
        if let cachedOrdered { return cachedOrdered }
        let pinned = items.filter { $0.pinned }
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
                item.displayText.localizedCaseInsensitiveContains(searchText)
            }
        }
        cachedFiltered = result
        return result
    }

    /// `baseDirectory` lets tests redirect storage away from Application Support.
    init(baseDirectory: URL? = nil, keyProvider: () throws -> SymmetricKey = EncryptedStore.persistentKey) {
        let appDir: URL
        if let baseDirectory {
            appDir = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            // App-support dir for history + images. The shared bundle id keeps the
            // Accessibility grant across updates.
            appDir = appSupport.appendingPathComponent("PasteBoard")
        }
        imageStorageURL = appDir.appendingPathComponent("Images")
        storageURL = appDir.appendingPathComponent("history.json")
        pinnedStorageURL = appDir.appendingPathComponent("pinned.json")

        // Create directories
        try? FileManager.default.createDirectory(at: imageStorageURL, withIntermediateDirectories: true)

        do {
            historyKey = try keyProvider()
        } catch {
            // Keychain unavailable (rare): fall back to a session-only key so the app
            // still runs — history just won't survive a restart decryptable.
            NSLog("PasteBoard: history key unavailable, using a session-only key — \(error.localizedDescription)")
            historyKey = SymmetricKey(size: .bits256)
        }

        loadItems()
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func checkForChanges() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

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

        // Check for images. PNG encoding and the disk write are the expensive part,
        // so they run on ioQueue rather than blocking the capture timer.
        if let image = NSImage(pasteboard: pasteboard) {
            ioQueue.async { [weak self] in
                guard let self else { return }
                let imageID = UUID().uuidString
                let imagePath = self.imageStorageURL.appendingPathComponent("\(imageID).png")
                guard let tiffData = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
                do {
                    try pngData.write(to: imagePath)
                } catch {
                    NSLog("PasteBoard: failed to write captured image — \(error.localizedDescription)")
                    return
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

        // Check for text
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let item = ClipboardItem(
                id: UUID(),
                type: Self.classifyText(text),
                textContent: text,
                imagePath: nil,
                filePaths: nil,
                timestamp: Date(),
                sourceApp: sourceApp
            )
            addItem(item)
        }
    }

    // MARK: - Classification (pure, internal so tests can exercise them)

    /// Classify pasted text as a code snippet or plain text.
    static func classifyText(_ text: String) -> ClipboardItemType {
        looksLikeCode(text) ? .code : .text
    }

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
        let codeChars = Set("{}();[]<>=+*/&|")
        let codeCharCount = trimmed.filter { codeChars.contains($0) }.count
        if Double(codeCharCount) / Double(trimmed.count) > 0.06 { score += 1 }

        if trimmed.contains("{") && trimmed.contains("}") { score += 1 }
        if trimmed.contains(";") { score += 1 }

        // Indented continuation lines strongly suggest source code.
        let lines = trimmed.components(separatedBy: "\n")
        if lines.count > 1,
           lines.contains(where: { $0.hasPrefix("    ") || $0.hasPrefix("\t") }) {
            score += 1
        }

        return score >= 2
    }

    // MARK: - Mutation

    private func addItem(_ item: ClipboardItem) {
        DispatchQueue.main.async {
            self.insert(item)
            // NOTE: reconstructed — fires the blink in AppDelegate on capture.
            NotificationCenter.default.post(name: .clipboardDidCapture, object: nil)
        }
    }

    /// Synchronous insertion core: de-duplicates, then enforces the window.
    /// Internal so the test target can drive history without the pasteboard.
    func insert(_ item: ClipboardItem) {
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
    }

    private func isContentDuplicate(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        switch (a.type, b.type) {
        case (.text, .text), (.text, .code), (.code, .text), (.code, .code):
            return a.textContent != nil && a.textContent == b.textContent
        case (.file, .file), (.folder, .folder), (.file, .folder), (.folder, .file):
            return a.filePaths != nil && a.filePaths == b.filePaths
        default:
            return false
        }
    }

    /// Enforce the 200-item window over unpinned items, leaving pinned ones untouched.
    private func trimUnpinned() {
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > maxItems else { return }
        let overflow = unpinned.suffix(unpinned.count - maxItems) // oldest unpinned
        let removeIDs = Set(overflow.map { $0.id })
        removeFiles(overflow.compactMap { $0.imagePath })
        items.removeAll { removeIDs.contains($0.id) }
    }

    func pasteItem(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text, .code:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let path = item.imagePath,
               let image = NSImage(contentsOfFile: path) {
                pasteboard.writeObjects([image])
            }
        case .file, .folder:
            if let paths = item.filePaths {
                let urls = paths.compactMap { URL(fileURLWithPath: $0) } as [NSURL]
                pasteboard.writeObjects(urls)
            }
        }

        // Update the change count so we don't re-capture what we just pasted
        lastChangeCount = pasteboard.changeCount
    }

    /// Paste a single member of a multi-file group (one file URL).
    func pasteSubPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        lastChangeCount = pasteboard.changeCount
    }

    /// Put plain text on the clipboard — used to paste a file's path into a terminal,
    /// which can't accept a file-url. Guards re-capture like the other paste methods.
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
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
        removeFiles([item.imagePath].compactMap { $0 })
        saveItems()
    }

    func clearAll() {
        // Preserve pinned items; only clear the rolling history.
        let imagePaths = items.filter { !$0.pinned }.compactMap { $0.imagePath }
        items.removeAll { !$0.pinned }         // instant UI update
        removeFiles(imagePaths)
        saveItems()
    }

    // MARK: - Keyboard navigation

    var selectedItem: ClipboardItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    func selectFirst() {
        selectedItemID = filteredItems.first?.id
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
            let count = list.count
            let newIndex = ((currentIndex + delta) % count + count) % count
            selectedItemID = list[newIndex].id
        } else {
            // Nothing selected yet: enter from the appropriate end.
            selectedItemID = (delta >= 0 ? list.first : list.last)?.id
        }
    }

    // MARK: - Persistence

    private func saveItems() {
        // Snapshot on the main thread, then encode + write off the main thread.
        // A burst of mutations (rapid pin toggles, a flurry of captures) collapses
        // into a single write via the debounced work item.
        let pinned = items.filter { $0.pinned }
        let unpinned = items.filter { !$0.pinned }
        let storageURL = self.storageURL
        let pinnedStorageURL = self.pinnedStorageURL
        let historyKey = self.historyKey
        pendingSave?.cancel()
        let work = DispatchWorkItem {
            do {
                let unpinnedData = try EncryptedStore.encrypt(JSONEncoder().encode(unpinned), key: historyKey)
                let pinnedData = try EncryptedStore.encrypt(JSONEncoder().encode(pinned), key: historyKey)
                try unpinnedData.write(to: storageURL)
                try pinnedData.write(to: pinnedStorageURL)
            } catch {
                NSLog("PasteBoard: failed to persist history — \(error.localizedDescription)")
            }
        }
        pendingSave = work
        ioQueue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    private func loadItems() {
        var pinned: [ClipboardItem] = []
        var unpinned: [ClipboardItem] = []
        if let data = try? Data(contentsOf: pinnedStorageURL),
           let saved = try? decodeHistory([ClipboardItem].self, from: data) {
            pinned = saved.map { var i = $0; i.pinned = true; return i }
        }
        if let data = try? Data(contentsOf: storageURL),
           let saved = try? decodeHistory([ClipboardItem].self, from: data) {
            unpinned = saved.map { var i = $0; i.pinned = false; return i }
        }
        // Keep a single recency-ordered array; `orderedItems` floats pins to the top.
        items = (pinned + unpinned).sorted { $0.timestamp > $1.timestamp }
    }

    /// Decrypts `data` (current on-disk format); falls back to plain JSON so
    /// histories written before encryption existed still load. The next save
    /// re-persists the file encrypted.
    private func decodeHistory<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let plaintext = (try? EncryptedStore.decrypt(data, key: historyKey)) ?? data
        return try JSONDecoder().decode(type, from: plaintext)
    }
}
