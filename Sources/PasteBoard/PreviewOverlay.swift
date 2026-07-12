import SwiftUI
import AppKit

/// ⌘Y full-content preview, drawn inside the same panel/window instead of a
/// separate QLPreviewPanel — that panel becomes its own key window with its own
/// event loop, which our local key monitor (installKeyMonitor) can't see into,
/// so a second ⌘Y had nowhere to land. Staying in-window means every existing
/// shortcut (⌘Y, Esc, arrows) keeps working exactly as it already does elsewhere.
struct PreviewOverlay: View {
    let item: ClipboardItem
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .foregroundColor(.secondary)
            Text("Preview")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text("esc / ⌘Y")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .image:
            ImagePreview(path: item.imagePath)
        case .text:
            TextPreview(text: item.textContent ?? "")
        case .code:
            CodePreview(code: item.textContent ?? "")
        case .file, .folder:
            FilePreview(item: item)
        }
    }
}

private struct ImagePreview: View {
    let path: String?
    @State private var image: NSImage?

    // Maximum edge length for the preview — prevents a 50MB screenshot from
    // filling memory. 800px is plenty for a panel-sized preview.
    private static let maxPreviewPixels = 800

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(12)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            guard let path else { return }
            image = await Task.detached(priority: .userInitiated) {
                downsampleImage(path: path, maxPixelSize: Self.maxPreviewPixels)
            }.value
        }
    }
}

private struct TextPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

private struct CodePreview: View {
    let code: String

    var body: some View {
        ScrollView {
            Text(SyntaxHighlighter.highlight(code))
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

private struct FilePreview: View {
    let item: ClipboardItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(item.filePaths ?? [], id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                            Text(path)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}
