#if DEBUG
import SwiftUI

// Temporary, DEBUG-only preview used purely to generate clean README screenshots
// with synthetic sample data (no real clipboard history). Safe to delete.

@MainActor
private func screenshotSampleManager() -> ClipboardManager {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pb-screenshot-sample", isDirectory: true)
    let manager = ClipboardManager(baseDirectory: tmp)
    let now = Date()
    manager.items = [
        ClipboardItem(
            id: UUID(), type: .text,
            textContent: "hello@example.com",
            imagePath: nil, filePaths: nil,
            timestamp: now, sourceApp: "Mail", pinned: true
        ),
        ClipboardItem(
            id: UUID(), type: .code,
            textContent: "func greet(_ name: String) {\n    print(\"Hello, \\(name)!\")\n}",
            imagePath: nil, filePaths: nil,
            timestamp: now.addingTimeInterval(-60), sourceApp: "Xcode"
        ),
        ClipboardItem(
            id: UUID(), type: .text,
            textContent: "https://github.com/araidz/PasteBoard",
            imagePath: nil, filePaths: nil,
            timestamp: now.addingTimeInterval(-120), sourceApp: "Safari"
        ),
        ClipboardItem(
            id: UUID(), type: .text,
            textContent: "Reminder: ship v1.0 on Friday and write the release announcement.",
            imagePath: nil, filePaths: nil,
            timestamp: now.addingTimeInterval(-180), sourceApp: "Notes"
        ),
        ClipboardItem(
            id: UUID(), type: .file,
            textContent: nil, imagePath: nil,
            filePaths: ["/Users/example/Documents/Q3-Report.pdf",
                        "/Users/example/Documents/Budget.xlsx"],
            timestamp: now.addingTimeInterval(-240), sourceApp: "Finder"
        ),
        ClipboardItem(
            id: UUID(), type: .folder,
            textContent: nil, imagePath: nil,
            filePaths: ["/Users/example/Projects/Website"],
            timestamp: now.addingTimeInterval(-300), sourceApp: "Finder"
        ),
    ]
    return manager
}

#Preview("PasteBoard") {
    ClipboardHistoryView(manager: screenshotSampleManager())
        .frame(width: 320, height: 480)
        .padding(56)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.40, blue: 0.92),
                    Color(red: 0.58, green: 0.30, blue: 0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
}
#endif
