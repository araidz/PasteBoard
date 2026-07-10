import SwiftUI
import AppKit

// Header (title + count + gear settings menu), search field, and the rich
// item list with Pinned/Recent section headers and ⌘1–9 quick-paste badges. The search
// field auto-focuses on open (via .panelDidShow). Highlight is keyboard-only; double-
// click commits (in the row).
struct HistoryView: View {
    @ObservedObject var manager: ClipboardManager
    let onCommit: (ClipboardItem) -> Void
    var onCommitPath: (String) -> Void = { _ in }
    var onToggleLaunchAtLogin: () -> Void = {}
    var isLaunchAtLogin: () -> Bool = { false }
    var onEnableAccessibility: () -> Void = {}
    var isTrusted: () -> Bool = { false }
    var onQuit: () -> Void = {}
    // Same UserDefaults key AppDelegate reads for the auto-paste gate; @AppStorage keeps
    // the menu checkmark live.
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 290, height: 520)
        .overlay {
            if manager.isPreviewing, let item = manager.selectedItem {
                PreviewOverlay(item: item) { manager.isPreviewing = false }
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        // Rapid ⌘Y/search toggling swaps whole view subtrees (overlay, list's
        // empty-vs-populated branch) back to back; SwiftUI's default implicit
        // transition tried to animate each swap and piled up into a runaway
        // layout loop under fast alternation. No animation, no pileup.
        .transaction { $0.disablesAnimations = true }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidShow)) { _ in
            searchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("PasteBoard")
                .font(.headline)
            Spacer()
            Text("\(manager.filteredItems.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            gearMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var gearMenu: some View {
        Menu {
            Toggle("Launch at Login", isOn: Binding(get: isLaunchAtLogin, set: { _ in onToggleLaunchAtLogin() }))
            Toggle("Paste Directly Into App", isOn: $autoPasteEnabled)
            // Only offer the enable action while it's still needed; once granted, the row goes away.
            if !isTrusted() {
                Button("Enable Accessibility…", action: onEnableAccessibility)
                Divider()
            }
            Menu("History Limit") {
                ForEach([50, 100, 200, 500, 1000], id: \.self) { n in
                    Toggle("\(n) items", isOn: Binding(get: { manager.maxItems == n }, set: { _ in manager.maxItems = n }))
                }
            }
            Divider()
            Button("Quit PasteBoard", action: onQuit)
        } label: {
            Image(systemName: "gearshape")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.caption)
            TextField("Search...", text: $manager.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !manager.searchText.isEmpty {
                Button { manager.searchText = "" } label: {
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
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var list: some View {
        if manager.filteredItems.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: manager.searchText.isEmpty ? "clipboard" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text(manager.searchText.isEmpty ? "No items yet" : "No matches")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                                onPastePath: { path in onCommitPath(path) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: manager.selectedItemID) { _, sel in
                    if let sel { withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(sel, anchor: .center) } }
                }
            }
        }
    }

    // "Pinned" atop pinned rows, "Recent" at the first unpinned row; nil elsewhere.
    private func sectionLabel(at index: Int) -> String? {
        let items = manager.filteredItems
        guard items.indices.contains(index) else { return nil }
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

    // Keyboard-shortcut legend on the left, Clear-all on the right — matches the OG bar.
    private var footer: some View {
        HStack(spacing: 9) {
            footerHint(symbol: "return", "paste")
            footerHint(keys: "⌘P", "pin")
            footerHint(keys: "⌘⌫", "delete")
            Spacer()
            Button {
                manager.clearAll()
            } label: {
                Label("clear all", systemImage: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear unpinned history")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerHint(symbol: String? = nil, keys: String? = nil, _ label: String) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            if let keys { Text(keys).font(.system(size: 11, weight: .medium)) }
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}
