import XCTest
@testable import PasteBoard

final class PasteBoardTests: XCTestCase {

    // A ClipboardManager backed by a throwaway temp directory so tests never
    // touch real Application Support data.
    private func makeManager() -> ClipboardManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-test-\(UUID().uuidString)", isDirectory: true)
        return ClipboardManager(baseDirectory: dir)
    }

    private func textItem(_ text: String, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(id: UUID(), type: ClipboardManager.classifyText(text),
                      textContent: text, imagePath: nil, filePaths: nil,
                      timestamp: Date(), sourceApp: nil, pinned: pinned)
    }

    // MARK: - Text classification

    func testClassifyCodeVsProse() {
        XCTAssertEqual(ClipboardManager.classifyText("func greet() {\n    return 1\n}"), .code)
        XCTAssertEqual(ClipboardManager.classifyText("Let me know what you think about this."), .text)
        // Too short to judge — defaults to plain text.
        XCTAssertEqual(ClipboardManager.classifyText("let x = 1"), .text)
    }

    // MARK: - File vs folder classification

    func testFileTypeDistinguishesFolders() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-ft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("note.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(ClipboardManager.fileType(forPaths: [folder.path]), .folder)
        XCTAssertEqual(ClipboardManager.fileType(forPaths: [file.path]), .file)
        // A mix of file + folder is not "all directories" → treated as files.
        XCTAssertEqual(ClipboardManager.fileType(forPaths: [folder.path, file.path]), .file)
    }

    // MARK: - URL / email / terminal heuristics (row icon selection)

    func testURLHeuristic() {
        XCTAssertTrue(ClipboardItemRow.looksLikeURL("https://example.com"))
        XCTAssertTrue(ClipboardItemRow.looksLikeURL("www.example.com"))
        XCTAssertFalse(ClipboardItemRow.looksLikeURL("hello world"))
        XCTAssertFalse(ClipboardItemRow.looksLikeURL("not a link"))
    }

    func testEmailHeuristic() {
        XCTAssertTrue(ClipboardItemRow.looksLikeEmail("a@example.com"))
        XCTAssertFalse(ClipboardItemRow.looksLikeEmail("a@b"))            // no dot in domain
        XCTAssertFalse(ClipboardItemRow.looksLikeEmail("hello there"))    // no @
        XCTAssertFalse(ClipboardItemRow.looksLikeEmail("a b@example.com")) // has a space
    }

    func testTerminalAppHeuristic() {
        XCTAssertTrue(ClipboardItemRow.isTerminalApp("iTerm2"))
        XCTAssertTrue(ClipboardItemRow.isTerminalApp("Ghostty"))
        XCTAssertFalse(ClipboardItemRow.isTerminalApp("Safari"))
    }

    // MARK: - insert(): dedup, pin carry-forward, ordering

    func testInsertDeduplicatesAndKeepsNewestOnTop() {
        let m = makeManager()
        m.insert(textItem("hello"))
        m.insert(textItem("world"))
        let newerHello = textItem("hello")
        m.insert(newerHello)

        XCTAssertEqual(m.items.count, 2, "duplicate text should collapse to one entry")
        XCTAssertEqual(m.items.first?.id, newerHello.id, "newest copy floats to the top")
    }

    func testInsertCarriesPinForward() {
        let m = makeManager()
        m.insert(textItem("keepme", pinned: true))
        // Re-copying the same content (unpinned) must not silently drop the pin.
        m.insert(textItem("keepme", pinned: false))

        XCTAssertEqual(m.items.count, 1)
        XCTAssertTrue(m.items.first?.pinned == true, "pin carries forward onto the newer duplicate")
    }

    func testOrderedItemsFloatsPinnedToTop() {
        let m = makeManager()
        m.insert(textItem("pinned-old", pinned: true))
        m.insert(textItem("newer-unpinned"))   // inserted at index 0

        XCTAssertEqual(m.items.first?.textContent, "newer-unpinned", "raw items stay recency-ordered")
        XCTAssertEqual(m.orderedItems.first?.textContent, "pinned-old", "display order floats pins up")
    }

    func testTrimDropsOldestUnpinnedButKeepsPinned() {
        let key = "maxItems"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let m = makeManager()
        m.maxItems = 3
        m.insert(textItem("PIN", pinned: true))
        for i in 0..<5 { m.insert(textItem("item-\(i)")) }

        let unpinned = m.items.filter { !$0.pinned }
        XCTAssertEqual(unpinned.count, 3, "window trims oldest unpinned down to maxItems")
        XCTAssertEqual(m.items.filter { $0.pinned }.count, 1, "pinned item is exempt from trimming")
    }

    // MARK: - Auto-paste decision

    func testAutoPasteActionRequiresEnabledTrustedAndNotSelf() {
        XCTAssertEqual(AutoPaste.action(autoPasteEnabled: true, trusted: true, targetIsSelf: false), .autoPaste)
        // Any one condition failing falls back to copy-only (never a silent no-op).
        XCTAssertEqual(AutoPaste.action(autoPasteEnabled: false, trusted: true, targetIsSelf: false), .copyOnly)
        XCTAssertEqual(AutoPaste.action(autoPasteEnabled: true, trusted: false, targetIsSelf: false), .copyOnly)
        XCTAssertEqual(AutoPaste.action(autoPasteEnabled: true, trusted: true, targetIsSelf: true), .copyOnly)
    }

    // MARK: - Syntax highlighting

    func testSyntaxTokenizerClassifiesSpans() {
        let code = "func greet() {\n    let n = 42 // count\n    return \"hi\"\n}"
        let kinds = SyntaxHighlighter.tokens(in: code).map(\.kind)
        XCTAssertTrue(kinds.contains(.keyword), "func/let/return should be keywords")
        XCTAssertTrue(kinds.contains(.number), "42 should be a number")
        XCTAssertTrue(kinds.contains(.comment), "// count should be a comment")
        XCTAssertTrue(kinds.contains(.string), "\"hi\" should be a string")
    }

    func testSyntaxTokenizerLeavesProseAlone() {
        // No code tokens in ordinary prose (the number is the only classified span).
        let kinds = SyntaxHighlighter.tokens(in: "just some words here").map(\.kind)
        XCTAssertTrue(kinds.isEmpty)
    }
}
