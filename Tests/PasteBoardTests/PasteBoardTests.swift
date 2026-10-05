import XCTest
@testable import PasteBoard
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

final class PasteBoardTests: XCTestCase {

    // Fresh, isolated storage per manager so nothing touches real history — and an
    // in-memory key so tests never read/write the real login Keychain.
    private static let ephemeralKey = SymmetricKey(size: .bits256)
    private func isolatedDefaults() -> UserDefaults {
        let suite = "PasteBoardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeManager() -> ClipboardManager {
        ClipboardManager(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            defaults: isolatedDefaults(),
            keyProvider: { Self.ephemeralKey }
        )
    }

    // Distinct ids (selection/dedup) and monotonic timestamps per built item.
    private var tick: TimeInterval = 0
    private func textItem(_ text: String, pinned: Bool = false) -> ClipboardItem {
        tick += 1
        return ClipboardItem(
            id: UUID(), type: .text, textContent: text,
            imagePath: nil, filePaths: nil,
            timestamp: Date(timeIntervalSince1970: tick),
            sourceApp: nil, pinned: pinned)
    }

    // 1. Pinned float above unpinned; within pinned, newest first.
    func testFilteredItemsOrdering() {
        let m = makeManager()
        let a = textItem("a")
        let b = textItem("b", pinned: true)
        let c = textItem("c")
        let d = textItem("d", pinned: true)
        m.items = [a, b, c, d]
        // pinned sorted by recency: [d, b] (d has higher tick), then unpinned [a, c].
        XCTAssertEqual(m.filteredItems.map(\.textContent), ["d", "b", "a", "c"])
    }

    // 2. Case-insensitive substring on displayText; empty -> all; no match -> empty.
    func testFilteredItemsSearch() {
        let m = makeManager()
        m.items = [textItem("Hello World"), textItem("goodbye"), textItem("HELLO there")]
        XCTAssertEqual(m.filteredItems.count, 3, "empty search returns all")

        m.searchText = "hello"
        XCTAssertEqual(m.filteredItems.map(\.textContent), ["Hello World", "HELLO there"])

        m.searchText = "zzz"
        XCTAssertTrue(m.filteredItems.isEmpty, "no match returns empty")
    }

    // 3. Wrap-around navigation over filteredItems, plus edge entries.
    func testMoveSelectionWrapAround() {
        // Down past last wraps to first.
        let down = makeManager()
        let a = textItem("a"), b = textItem("b"), c = textItem("c")
        down.items = [a, b, c]
        down.selectedItemID = c.id
        down.moveSelection(by: 1)
        XCTAssertEqual(down.selectedItemID, a.id)

        // Up past first wraps to last.
        let up = makeManager()
        up.items = [a, b, c]
        up.selectedItemID = a.id
        up.moveSelection(by: -1)
        XCTAssertEqual(up.selectedItemID, c.id)

        // Single item: either direction stays put.
        let single = makeManager()
        single.items = [a]
        single.selectedItemID = a.id
        single.moveSelection(by: 1)
        XCTAssertEqual(single.selectedItemID, a.id)
        single.moveSelection(by: -1)
        XCTAssertEqual(single.selectedItemID, a.id)

        // Empty list clears the selection.
        let empty = makeManager()
        empty.selectedItemID = UUID()
        empty.moveSelection(by: 1)
        XCTAssertNil(empty.selectedItemID)

        // No selection: +delta enters at first, -delta enters at last.
        let entryFirst = makeManager()
        entryFirst.items = [a, b, c]
        entryFirst.moveSelection(by: 1)
        XCTAssertEqual(entryFirst.selectedItemID, a.id)

        let entryLast = makeManager()
        entryLast.items = [a, b, c]
        entryLast.moveSelection(by: -1)
        XCTAssertEqual(entryLast.selectedItemID, c.id)
    }

    // 4. Deleting the selected row moves the highlight sensibly.
    func testDeleteItemReselection() {
        let a = textItem("a"), b = textItem("b"), c = textItem("c")

        // Middle selected -> following row.
        let mid = makeManager()
        mid.items = [a, b, c]
        mid.selectedItemID = b.id
        mid.deleteItem(b)
        XCTAssertEqual(mid.selectedItemID, c.id)

        // Last selected -> new last row.
        let last = makeManager()
        last.items = [a, b, c]
        last.selectedItemID = c.id
        last.deleteItem(c)
        XCTAssertEqual(last.selectedItemID, b.id)

        // Only row selected -> nil.
        let only = makeManager()
        only.items = [a]
        only.selectedItemID = a.id
        only.deleteItem(a)
        XCTAssertNil(only.selectedItemID)
        XCTAssertTrue(only.items.isEmpty)
    }

    // 5. Deleting a pinned item is a no-op.
    func testDeleteItemPinnedProtection() {
        let m = makeManager()
        let p = textItem("p", pinned: true)
        m.items = [p]
        m.deleteItem(p)
        XCTAssertEqual(m.items.count, 1)
        XCTAssertTrue(m.items.contains { $0.id == p.id })
    }

    // 6. Toggling pin floats an item to the top of orderedItems; toggling again returns it.
    func testTogglePinFloatsAndReturns() {
        let m = makeManager()
        let a = textItem("a"), b = textItem("b"), c = textItem("c")
        m.items = [a, b, c]
        XCTAssertEqual(m.orderedItems.map(\.textContent), ["a", "b", "c"])

        m.togglePin(c)
        XCTAssertEqual(m.orderedItems.map(\.textContent), ["c", "a", "b"])

        m.togglePin(c)
        XCTAssertEqual(m.orderedItems.map(\.textContent), ["a", "b", "c"])
    }

    // 7. A selection filtered out by a new searchText is cleared; one still shown is kept.
    func testSearchTextClearsFilteredOutSelection() {
        let m = makeManager()
        let apple = textItem("apple"), banana = textItem("banana")
        m.items = [apple, banana]

        m.selectedItemID = banana.id
        m.searchText = "app"                 // banana filtered out
        XCTAssertNil(m.selectedItemID)

        m.selectedItemID = apple.id
        m.searchText = "apple"               // apple still visible
        XCTAssertEqual(m.selectedItemID, apple.id)
    }

    // 8. insert() caps unpinned to maxItems (newest kept); pinned items are exempt.
    func testMaxItemsCapUnpinnedNewestKeptPinnedExempt() {
        let m = makeManager()
        m.maxItems = 2
        let pinned = textItem("pinned", pinned: true)
        m.items = [pinned]

        // Insert four distinct unpinned items (distinct content avoids dedup collapse).
        for i in 0..<4 { m.insert(textItem("u\(i)")) }

        let unpinned = m.items.filter { !$0.pinned }
        XCTAssertEqual(unpinned.map(\.textContent), ["u3", "u2"], "newest unpinned kept, oldest trimmed")
        XCTAssertTrue(m.items.contains { $0.id == pinned.id }, "pinned item exempt from cap")
    }

    // 9. EncryptedStore round-trips data, and the ciphertext doesn't contain the
    //    plaintext (proves it's actually encrypted, not just re-encoded).
    func testEncryptedStoreRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let secret = "correct horse battery staple"
        let plaintext = Data(secret.utf8)

        let ciphertext = try EncryptedStore.encrypt(plaintext, key: key)
        XCTAssertFalse(String(data: ciphertext, encoding: .utf8)?.contains(secret) ?? false)

        let decrypted = try EncryptedStore.decrypt(ciphertext, key: key)
        XCTAssertEqual(decrypted, plaintext)

        XCTAssertThrowsError(try EncryptedStore.decrypt(ciphertext, key: SymmetricKey(size: .bits256)),
                              "wrong key must not decrypt")
    }

    // 10. A saved history is encrypted on disk, and reloads through a fresh
    //     ClipboardManager pointed at the same storage dir + key.
    func testHistoryPersistsEncryptedAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        let secret = "super-secret-token-\(UUID().uuidString)"

        let writer = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { key })
        writer.insert(textItem(secret))

        writer.flush()

        let onDisk = try Data(contentsOf: dir.appendingPathComponent("history.json"))
        XCTAssertFalse(String(data: onDisk, encoding: .utf8)?.contains(secret) ?? false,
                        "history.json must not contain the plaintext secret")

        let reader = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { key })
        XCTAssertTrue(reader.items.contains { $0.textContent == secret })
    }

    // 11. Histories written before encryption existed (plain JSON) still load —
    //     upgrading the app must not strand existing users' history.
    func testLegacyPlaintextHistoryStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacyItem = textItem("pre-encryption-item")
        try JSONEncoder().encode([legacyItem]).write(to: dir.appendingPathComponent("history.json"))

        let manager = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { SymmetricKey(size: .bits256) })
        XCTAssertTrue(manager.items.contains { $0.textContent == "pre-encryption-item" })
    }

    // MARK: - Phase 1: Critical Fixes

    // 12. EncryptedStore errors provide diagnostic info (not opaque CocoaError).
    func testEncryptedStoreErrorDescriptions() {
        let encErr = EncryptedStoreError.encryptionFailed
        XCTAssertTrue(encErr.description.contains("encryption"))

        let readErr = EncryptedStoreError.keychainReadFailed(errSecItemNotFound)
        XCTAssertTrue(readErr.description.contains("read"))
        XCTAssertTrue(readErr.description.contains("\(errSecItemNotFound)"))

        let writeErr = EncryptedStoreError.keychainWriteFailed(errSecDuplicateItem)
        XCTAssertTrue(writeErr.description.contains("write"))
        XCTAssertTrue(writeErr.description.contains("\(errSecDuplicateItem)"))
    }

    // 13. shellEscape handles every path as one single-quoted shell word.
    func testShellEscape() {
        XCTAssertEqual(AppDelegate.shellEscape("/Users/me/file.txt"),
                       "'/Users/me/file.txt'")

        XCTAssertEqual(AppDelegate.shellEscape("/Users/me/My File.txt"),
                       "'/Users/me/My File.txt'")

        XCTAssertEqual(AppDelegate.shellEscape("/Users/me/it's here.txt"),
                       "'/Users/me/it'\\''s here.txt'")

        XCTAssertEqual(AppDelegate.shellEscape("/tmp/a\nb"), "'/tmp/a\nb'")
        XCTAssertEqual(AppDelegate.shellEscape(""), "''")

        XCTAssertEqual(AppDelegate.shellEscape("/tmp/$HOME `whoami` !*"),
                       "'/tmp/$HOME `whoami` !*'")
    }

    // MARK: - Phase 2: Core Manager

    // 14. Pinned items sorted by recency (newest first), not insertion order.
    func testPinnedItemsSortedByRecency() {
        let m = makeManager()
        let old = textItem("old-pinned", pinned: true)  // tick=1
        let newer = textItem("newer-pinned", pinned: true) // tick=2
        let newest = textItem("newest-pinned", pinned: true) // tick=3
        let unpinned = textItem("unpinned")
        // Insert in non-chronological order.
        m.items = [old, unpinned, newest, newer]
        XCTAssertEqual(m.orderedItems.map(\.textContent),
                       ["newest-pinned", "newer-pinned", "old-pinned", "unpinned"])
    }

    // 15. Unreadable history stays untouched and disables startup cleanup.
    func testUnreadableHistoryAndImagesStayUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = dir.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let history = dir.appendingPathComponent("history.json")
        let image = images.appendingPathComponent("existing.png")
        let original = Data("NOT_VALID_JSON_OR_ENCRYPTED".utf8)
        try original.write(to: history)
        try Data("existing image".utf8).write(to: image)

        let manager = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { SymmetricKey(size: .bits256) })
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: history), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertFalse(manager.isCaptureEnabled)
    }

    func testExistingButUnreadableHistoryDisablesCapture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = dir.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)

        let manager = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { Self.ephemeralKey })

        XCTAssertFalse(manager.isCaptureEnabled)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testInvalidMaxItemsIsClamped() {
        let defaults = isolatedDefaults()
        defaults.set(-100, forKey: "maxItems")
        let manager = ClipboardManager(
            baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            defaults: defaults,
            keyProvider: { Self.ephemeralKey }
        )
        XCTAssertEqual(manager.maxItems, 1)
        manager.maxItems = .max
        XCTAssertEqual(manager.maxItems, 1_000)
    }

    func testImageDecodedPixelLimit() throws {
        XCTAssertTrue(ClipboardManager.imageDimensionsAreSafe(width: 8_000, height: 5_000))
        XCTAssertFalse(ClipboardManager.imageDimensionsAreSafe(width: 8_001, height: 5_000))
        XCTAssertFalse(ClipboardManager.imageDimensionsAreSafe(width: .max, height: 2))
        XCTAssertFalse(ClipboardManager.imageDimensionsAreSafe(width: 0, height: 100))

        func image(width: Int, height: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }

        let singleFrameData = NSMutableData()
        let singleFrameDestination = try XCTUnwrap(CGImageDestinationCreateWithData(
            singleFrameData, UTType.tiff.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(singleFrameDestination, try image(width: 16, height: 16), nil)
        XCTAssertTrue(CGImageDestinationFinalize(singleFrameDestination))
        XCTAssertTrue(ClipboardManager.imageDimensionsAreSafe(singleFrameData as Data))

        XCTAssertTrue(ClipboardManager.imageDimensionsAreSafe(width: 5_000, height: 5_000))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 2, nil
        ))
        CGImageDestinationAddImage(destination, try image(width: 5_000, height: 5_000), nil)
        CGImageDestinationAddImage(destination, try image(width: 5_000, height: 5_000), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(CGImageSourceGetCount(try XCTUnwrap(CGImageSourceCreateWithData(data, nil))), 2)
        XCTAssertFalse(ClipboardManager.imageDimensionsAreSafe(data as Data))
    }

    // 16. Image items dedup by file path.
    func testImageDeduplication() {
        let m = makeManager()
        let imgPath = "/tmp/test-image-\(UUID().uuidString).png"
        let a = ClipboardItem(id: UUID(), type: .image, textContent: nil,
                              imagePath: imgPath, filePaths: nil,
                              timestamp: Date(), sourceApp: nil)
        let b = ClipboardItem(id: UUID(), type: .image, textContent: nil,
                              imagePath: imgPath, filePaths: nil,
                              timestamp: Date(), sourceApp: nil)
        let newer = textItem("newer")
        m.items = [newer, a]
        m.insert(b)
        // b should replace a (same path = same image) and move to the top.
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(m.items.first?.id, b.id)
    }

    // Formatted copies paste with their RTF; plain paste drops it; both survive a reload.
    func testRichTextPasteAndPersistence() throws {
        let rtf = Data(#"{\rtf1\ansi {\b bold}}"#.utf8)
        var item = textItem("bold")
        item.richData = rtf
        item.richType = NSPasteboard.PasteboardType.rtf.rawValue

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { Self.ephemeralKey })
        let pasteboard = NSPasteboard(name: .init("PasteBoardTests.\(UUID().uuidString)"))

        XCTAssertTrue(m.pasteItem(item, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.string(forType: .string), "bold")

        XCTAssertTrue(m.pasteItem(item, to: pasteboard, plain: true))
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertEqual(pasteboard.string(forType: .string), "bold")

        m.insert(item)
        m.flush()
        let reloaded = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { Self.ephemeralKey })
        XCTAssertEqual(reloaded.items.first?.richData, rtf)

        // Same text but newly formatted is not treated as a re-asserted copy.
        XCTAssertTrue(m.insert(textItem("plain-first")))
        var formatted = textItem("plain-first")
        formatted.richData = rtf
        formatted.richType = item.richType
        XCTAssertTrue(m.insert(formatted))
        XCTAssertEqual(m.items.first?.richData, rtf)
    }

    // Vision reads text from a rendered image, and that text becomes searchable.
    func testOCRTextIsRecognizedAndSearchable() throws {
        let image = NSImage(size: NSSize(width: 600, height: 120), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Invoice 4821" as NSString).draw(at: NSPoint(x: 20, y: 30),
                withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let text = try XCTUnwrap(ClipboardManager.recognizeText(in: png))
        XCTAssertTrue(text.contains("4821"), "recognized: \(text)")

        let m = makeManager()
        let img = ClipboardItem(id: UUID(), type: .image, textContent: nil, imagePath: "/tmp/x.png",
                                filePaths: nil, timestamp: Date(), sourceApp: nil)
        m.items = [img, textItem("unrelated")]
        m.setOCRText(text, for: img.id)
        m.searchText = "invoice"
        XCTAssertEqual(m.filteredItems.map(\.id), [img.id])
    }

    // ⌘Z restores the last deleted item at its original position; committing ends undo.
    func testUndoDeleteRestoresPosition() {
        let m = makeManager()
        let a = textItem("a"), b = textItem("b"), c = textItem("c")
        m.items = [a, b, c]
        m.deleteItem(b)
        XCTAssertTrue(m.canUndoDelete)
        m.undoDelete()
        XCTAssertEqual(m.items.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(m.selectedItemID, b.id)
        XCTAssertFalse(m.canUndoDelete)

        m.deleteItem(c)
        m.commitPendingDelete()
        m.undoDelete()
        XCTAssertEqual(m.items.map(\.id), [a.id, b.id])
    }

    // A deleted image's file survives until the delete is committed.
    func testDeletedImageFileKeptUntilCommit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let m = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { Self.ephemeralKey })
        let file = dir.appendingPathComponent("Images/x.png")
        try Data("png".utf8).write(to: file)
        let img = ClipboardItem(id: UUID(), type: .image, textContent: nil, imagePath: file.path,
                                filePaths: nil, timestamp: Date(), sourceApp: nil)
        m.items = [img]
        m.deleteItem(img)
        m.flush()   // drains ioQueue — and commits the delete
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try Data("png".utf8).write(to: file)
        m.items = [img]
        m.deleteItem(img)
        m.undoDelete()
        m.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // "Ignore Next Copy" skips exactly one clipboard change, then disarms.
    func testIgnoreNextCopySkipsOneChange() {
        let m = makeManager()
        let pasteboard = NSPasteboard(name: .init("PasteBoardTests.\(UUID().uuidString)"))
        m.ignoreNextCopy = true
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)
        m.checkForChanges(pasteboard)
        XCTAssertFalse(m.ignoreNextCopy)

        let captured = expectation(forNotification: .clipboardDidCapture, object: nil)
        pasteboard.clearContents()
        pasteboard.setString("ordinary", forType: .string)
        m.checkForChanges(pasteboard)
        wait(for: [captured], timeout: 3)
        XCTAssertEqual(m.items.map(\.textContent), ["ordinary"])
    }

    // A copy repeating the newest entry (apps re-asserting the clipboard) is a no-op.
    func testReassertedTopCopyIsSkipped() {
        let m = makeManager()
        let first = textItem("same")
        XCTAssertTrue(m.insert(first))
        XCTAssertFalse(m.insert(textItem("same")))
        XCTAssertEqual(m.items.map(\.id), [first.id])
    }

    // 17. maxItemSizeBytes defaults to 10MB.
    func testMaxItemSizeBytesDefault() {
        let m = makeManager()
        XCTAssertEqual(m.maxItemSizeBytes, 10_000_000)
    }

    // 18. Rapid insertions don't lose data.
    func testRapidInsertionsDontLoseData() {
        let m = makeManager()
        m.maxItems = 50
        for i in 0..<20 {
            let item = ClipboardItem(
                id: UUID(), type: .text, textContent: "rapid-\(UUID().uuidString)",
                imagePath: nil, filePaths: nil,
                timestamp: Date(timeIntervalSince1970: Double(i)),
                sourceApp: nil
            )
            m.insert(item)
        }
        XCTAssertEqual(m.items.count, 20, "all 20 rapid insertions preserved in memory")
    }

    // MARK: - Phase 3: Performance

    // 19. SyntaxHighlighter cache works correctly — same input returns same output.
    func testSyntaxHighlighterCache() {
        let code = "func hello() { return 42 }"
        let first = SyntaxHighlighter.highlight(code)
        let second = SyntaxHighlighter.highlight(code)
        XCTAssertEqual(first, second, "cached result should equal fresh result")
    }

    // 20. Orphaned image files are cleaned up on launch.
    func testOrphanedImageCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let imageDir = dir.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        // Create an orphaned image file.
        let orphan = imageDir.appendingPathComponent("orphan.png")
        try "not-an-image".data(using: .utf8)!.write(to: orphan)

        // Create a referenced image file.
        let referenced = imageDir.appendingPathComponent("referenced.png")
        try "also-not-an-image".data(using: .utf8)!.write(to: referenced)

        // Pre-write a history file that references only "referenced" so that
        // loadItems picks it up before cleanupOrphanedImages runs.
        let key = SymmetricKey(size: .bits256)
        let item = ClipboardItem(
            id: UUID(), type: .image, textContent: nil,
            imagePath: referenced.standardizedFileURL.path, filePaths: nil,
            timestamp: Date(), sourceApp: nil
        )
        let data = try EncryptedStore.encrypt(JSONEncoder().encode([item]), key: key)
        try data.write(to: dir.appendingPathComponent("history.json"))

        // Creating the manager triggers loadItems + cleanupOrphanedImages.
        let manager = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults(), keyProvider: { key })

        withExtendedLifetime(manager) {
            // Wait for async cleanup on ioQueue.
            let cleaned = expectation(description: "orphan cleanup")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { cleaned.fulfill() }
            wait(for: [cleaned], timeout: 3)

            XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                           "orphaned image should be deleted")
            XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path),
                          "referenced image should survive")
        }
    }

    // 21. fileIconName returns correct icons for known extensions.
    func testFileIconName() {
        XCTAssertEqual(fileIconName(forPath: "test.swift"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(fileIconName(forPath: "test.png"), "photo")
        XCTAssertEqual(fileIconName(forPath: "test.pdf"), "doc.richtext")
        XCTAssertEqual(fileIconName(forPath: "test.unknown"), "doc")
    }

    func testConcealedAndTransientPasteboardsAreIgnored() {
        XCTAssertTrue(ClipboardManager.shouldIgnore(types: [.init("org.nspasteboard.ConcealedType")]))
        XCTAssertTrue(ClipboardManager.shouldIgnore(types: [.init("org.nspasteboard.TransientType")]))
        XCTAssertTrue(ClipboardManager.shouldIgnore(types: [.init("org.nspasteboard.AutoGeneratedType")]))
        XCTAssertFalse(ClipboardManager.shouldIgnore(types: [.string, .png]))
    }

    func testMissingImageDoesNotClearClipboard() {
        let manager = makeManager()
        let pasteboard = NSPasteboard(name: .init("PasteBoardTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        let missing = ClipboardItem(
            id: UUID(), type: .image, textContent: nil,
            imagePath: "/does/not/exist.png", filePaths: nil,
            timestamp: Date(), sourceApp: nil
        )

        XCTAssertFalse(manager.pasteItem(missing, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testKeyProviderFailureLeavesStoredDataUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = dir.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let history = dir.appendingPathComponent("history.json")
        let image = images.appendingPathComponent("existing.png")
        let original = Data("encrypted history".utf8)
        try original.write(to: history)
        try Data("existing image".utf8).write(to: image)

        _ = ClipboardManager(baseDirectory: dir, defaults: isolatedDefaults()) {
            throw EncryptedStoreError.keychainReadFailed(errSecAuthFailed)
        }

        XCTAssertEqual(try Data(contentsOf: history), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }
}
