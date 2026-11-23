import SwiftUI

struct ClipboardHistoryWindowView: View {
    private static let maxPreviewCharacters = 20_000

    let appModel: AppModel
    /// Optional override dismiss handler. When the view is hosted inside an
    /// NSPanel (e.g. `ClipboardHistoryPanelPresenter`), the SwiftUI
    /// `dismissWindow` environment action is unavailable, so callers can
    /// supply their own closure instead.
    var onDismiss: (() -> Void)? = nil

    @State private var searchText = ""
    @State private var selectedFilter: ClipboardContentType = .all
    @FocusState private var isSearchFocused: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            HSplitView {
                historyListColumn
                    .frame(
                        minWidth: ClipboardHistoryLayout.sidebarWidth,
                        idealWidth: ClipboardHistoryLayout.sidebarWidth,
                        maxWidth: ClipboardHistoryLayout.sidebarWidth,
                        maxHeight: .infinity
                    )

                detailColumn
                    .frame(
                        minWidth: ClipboardHistoryLayout.detailWidth,
                        idealWidth: ClipboardHistoryLayout.detailWidth,
                        maxHeight: .infinity
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerBar
        }
        .background(Color.clear)
        .onExitCommand {
            performDismiss()
        }
        .onAppear {
            syncQueryToModel()
            syncSelectionToVisibleEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryMoveSelection)) { notification in
            guard let direction = moveDirection(from: notification) else {
                appModel.logClipboardHistoryNavigation(
                    "Ignored clipboard history move notification",
                    metadata: ["user_info": "\(notification.userInfo ?? [:])"]
                )
                return
            }
            appModel.logClipboardHistoryNavigation(
                "Received clipboard history move notification",
                metadata: [
                    "direction": "\(direction)",
                    "selected_id": appModel.selectedClipboardEntryID?.uuidString ?? "nil",
                    "visible_count": "\(visibleEntries.count)",
                ]
            )
            moveSelection(direction)
        }
        .onChange(of: appModel.clipboardHistoryEntries.map(\.id)) { _, _ in
            syncSelectionToVisibleEntries()
        }
    }

    private var groupedEntries: [(title: String, entries: [ClipboardHistorySummary])] {
        let calendar = Calendar.current
        let today = Date()
        let grouped = Dictionary(grouping: appModel.clipboardHistoryEntries) { entry -> String in
            if calendar.isDate(entry.capturedAt, inSameDayAs: today) {
                return "Today"
            }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
               calendar.isDate(entry.capturedAt, inSameDayAs: yesterday) {
                return "Yesterday"
            }
            return entry.capturedAt.formatted(date: .abbreviated, time: .omitted)
        }

        return grouped
            .map { (title: $0.key, entries: $0.value.sorted { $0.capturedAt > $1.capturedAt }) }
            .sorted { lhs, rhs in
                guard let lhsDate = lhs.entries.first?.capturedAt,
                      let rhsDate = rhs.entries.first?.capturedAt else { return false }
                return lhsDate > rhsDate
            }
    }

    private var visibleEntries: [ClipboardHistorySummary] {
        groupedEntries.flatMap(\.entries)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                TextField("Type to filter entries...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .focused($isSearchFocused)
                    .onChange(of: searchText) { _, _ in
                        syncQueryToModel()
                    }

                Spacer(minLength: 8)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1, height: 18)

                Menu {
                    ForEach(ClipboardContentType.allCases) { type in
                        Button {
                            selectedFilter = type
                            syncQueryToModel()
                        } label: {
                            if selectedFilter == type {
                                Label(type.displayName, systemImage: "checkmark")
                            } else {
                                Text(type.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedFilter.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                    .frame(minWidth: 120, alignment: .trailing)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, ClipboardHistoryLayout.searchFieldHorizontalPadding)
            .padding(.vertical, ClipboardHistoryLayout.searchFieldVerticalPadding)
            .frame(height: 38)
            .liquidGlassCard(cornerRadius: ClipboardHistoryLayout.controlCornerRadius)
            .animation(.easeInOut(duration: 0.18), value: isSearchFocused)
        }
        .padding(.horizontal, ClipboardHistoryLayout.outerHorizontalPadding)
        .padding(.vertical, ClipboardHistoryLayout.barVerticalPadding)
    }

    private var historyListColumn: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(groupedEntries, id: \.title) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            ClipboardHistoryRow(
                                entry: entry,
                                isSelected: appModel.selectedClipboardEntryID == entry.id
                            )
                                .id(entry.id)
                                .onTapGesture {
                                    appModel.selectClipboardEntry(id: entry.id)
                                }
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        appModel.selectClipboardEntry(id: entry.id)
                                        appModel.pasteClipboardEntryToSelection(id: entry.id)
                                        performDismiss()
                                    }
                                )
                                .onAppear {
                                    appModel.loadMoreClipboardHistoryEntriesIfNeeded(currentEntryID: entry.id)
                                }
                                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.72))
                            .textCase(nil)
                            .padding(.leading, 8)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .overlay {
                if groupedEntries.isEmpty && isFiltering {
                    Text("No Results")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: appModel.selectedClipboardEntryID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }

    /// `true` when the user has typed a search query or selected a non-all filter.
    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedFilter != .all
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let entry = selectedVisibleEntry {
            VStack(spacing: 0) {
                contentPreview(for: entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                ClipboardMetadataPanel(entry: entry)
            }
            .background(Color.clear)
        } else if let summary = selectedVisibleSummary {
            VStack(spacing: 0) {
                summaryPreview(for: summary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                ClipboardSummaryMetadataPanel(entry: summary)
            }
            .background(Color.clear)
        } else if appModel.isLoadingSelectedClipboardEntry {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isFiltering {
            // There are clipboard items, but none match the current search/filter.
            ContentUnavailableView.search(text: searchText.isEmpty ? selectedFilter.displayName : searchText)
        } else {
            // Clipboard history is genuinely empty.
            ContentUnavailableView(
                "No Clipboard Items",
                systemImage: "clipboard",
                description: Text("Copy something to start building clipboard history.")
            )
        }
    }

    @ViewBuilder
    private func summaryPreview(for entry: ClipboardHistorySummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch entry.contentType {
                case .image:
                    Label(entry.title, systemImage: entry.contentType.iconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                case .file:
                    textPreview(entry.plainText ?? entry.subtitle ?? entry.title)
                default:
                    textPreview(entry.plainText ?? entry.title)
                }
            }
            .padding(.horizontal, ClipboardHistoryLayout.detailHorizontalPadding)
            .padding(.vertical, ClipboardHistoryLayout.detailVerticalPadding)
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Label("Clipboard History", systemImage: "clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            Button("Close") {
                performDismiss()
            }
            .liquidGlassButton(prominent: false)
            .fixedSize()

            Button("Paste") {
                guard let selectedEntryID = selectedVisibleEntry?.id else { return }
                appModel.pasteClipboardEntryToSelection(id: selectedEntryID)
                performDismiss()
            }
            .liquidGlassButton(prominent: true)
            .fixedSize()
            .disabled(selectedVisibleEntry == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ClipboardHistoryLayout.outerHorizontalPadding)
        .padding(.vertical, ClipboardHistoryLayout.barVerticalPadding)
    }

    @ViewBuilder
    private func contentPreview(for entry: ClipboardHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch entry.contentType {
                case .image:
                    if let image = entry.imagePreview {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            )
                    }
                case .file:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.fileURLs, id: \.self) { fileURL in
                            Label(fileURL.lastPathComponent, systemImage: "doc")
                                .font(.system(size: 13, weight: .medium))
                            Text(fileURL.path)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                default:
                    textPreview(entry.plainText ?? entry.subtitle ?? "")
                }
            }
            .padding(.horizontal, ClipboardHistoryLayout.detailHorizontalPadding)
            .padding(.vertical, ClipboardHistoryLayout.detailVerticalPadding)
        }
    }

    @ViewBuilder
    private func textPreview(_ text: String) -> some View {
        let preview = previewText(for: text)
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.text)
                .font(.system(size: 12, weight: .regular))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)

            if preview.isTruncated {
                Text("Preview truncated at \(Self.maxPreviewCharacters.formatted()) of \(text.count.formatted()) characters.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func previewText(for text: String) -> (text: String, isTruncated: Bool) {
        guard text.count > Self.maxPreviewCharacters else {
            return (text, false)
        }
        return (String(text.prefix(Self.maxPreviewCharacters)), true)
    }

    private var selectedVisibleEntry: ClipboardHistoryEntry? {
        if let selectedClipboardEntryID = appModel.selectedClipboardEntryID,
           appModel.clipboardHistoryEntries.contains(where: { $0.id == selectedClipboardEntryID }) {
            return appModel.selectedClipboardEntry
        }
        return nil
    }

    private var selectedVisibleSummary: ClipboardHistorySummary? {
        guard let selectedClipboardEntryID = appModel.selectedClipboardEntryID else { return nil }
        return appModel.clipboardHistoryEntries.first { $0.id == selectedClipboardEntryID }
    }

    // MARK: - Helpers

    private func performDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismissWindow(id: AppModel.clipboardHistoryWindowID)
        }
    }

    private func syncSelectionToVisibleEntries() {
        if let selectedClipboardEntryID = appModel.selectedClipboardEntryID,
           appModel.clipboardHistoryEntries.contains(where: { $0.id == selectedClipboardEntryID }) {
            return
        }

        appModel.selectClipboardEntry(id: appModel.clipboardHistoryEntries.first?.id)
    }

    private func syncQueryToModel() {
        appModel.updateClipboardHistoryQuery(searchText: searchText, filter: selectedFilter)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let entries = visibleEntries
        guard !entries.isEmpty else {
            appModel.logClipboardHistoryNavigation(
                "Ignored clipboard history move because no entries are visible",
                metadata: ["direction": "\(direction)"]
            )
            return
        }

        let selectedIndex = appModel.selectedClipboardEntryID.flatMap { selectedID in
            entries.firstIndex { $0.id == selectedID }
        }

        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max((selectedIndex ?? 0) - 1, 0)
        case .down:
            nextIndex = min((selectedIndex ?? -1) + 1, entries.count - 1)
        default:
            return
        }

        appModel.logClipboardHistoryNavigation(
            "Moving clipboard history selection",
            metadata: [
                "direction": "\(direction)",
                "selected_index": selectedIndex.map(String.init) ?? "nil",
                "next_index": "\(nextIndex)",
                "current_id": appModel.selectedClipboardEntryID?.uuidString ?? "nil",
                "next_id": entries[nextIndex].id.uuidString,
                "visible_count": "\(entries.count)",
            ]
        )
        appModel.selectClipboardEntry(id: entries[nextIndex].id)
        appModel.loadMoreClipboardHistoryEntriesIfNeeded(currentEntryID: entries[nextIndex].id)
    }

    private func moveDirection(from notification: Notification) -> MoveCommandDirection? {
        guard let rawValue = notification.userInfo?["direction"] as? String else { return nil }
        switch rawValue {
        case "up":
            return .up
        case "down":
            return .down
        default:
            return nil
        }
    }

}

extension Notification.Name {
    static let clipboardHistoryMoveSelection = Notification.Name("daydream.clipboardHistoryMoveSelection")
}

private struct ClipboardHistoryRow: View {
    let entry: ClipboardHistorySummary
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(backgroundFill)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color(nsColor: .secondaryLabelColor).opacity(0.34)
        }

        if isHovered {
            return Color(nsColor: .tertiaryLabelColor).opacity(0.2)
        }

        return .clear
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            Image(systemName: entry.contentType.iconName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
        }
        .frame(width: 18, height: 18, alignment: .center)
    }

}

private struct ClipboardMetadataPanel: View {
    let entry: ClipboardHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metadataRow("Source") {
                sourceValueView
            }
            metadataRow("Content type") {
                metadataValueText(contentTypeLabel)
            }
            metadataRow("Captured") {
                metadataValueText(entry.capturedAt.formatted(date: .numeric, time: .shortened))
            }
            metadataRow("Characters") {
                metadataValueText("\(entry.plainText?.count ?? 0)")
            }
            metadataRow("Words") {
                metadataValueText("\(entry.plainText?.split { $0.isWhitespace || $0.isNewline }.count ?? 0)")
            }
        }
        .padding(.vertical, ClipboardHistoryLayout.metadataVerticalPadding)
    }

    private func metadataRow<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                value()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(.secondary)

                value()
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, ClipboardHistoryLayout.outerHorizontalPadding + 8)
        .padding(.vertical, ClipboardHistoryLayout.metadataRowVerticalPadding)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.horizontal, ClipboardHistoryLayout.outerHorizontalPadding + 8)
        }
    }

    @ViewBuilder
    private var sourceValueView: some View {
        if let icon = sourceApplicationIcon {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(entry.sourceAppName)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            metadataValueText(entry.sourceAppName)
        }
    }

    private func metadataValueText(_ value: String) -> some View {
        Text(value)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .multilineTextAlignment(.trailing)
    }

    private var sourceApplicationIcon: NSImage? {
        guard let bundleIdentifier = entry.sourceAppBundleIdentifier,
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private var contentTypeLabel: String {
        switch entry.contentType {
        case .text:
            return "Text (Formatted)"
        default:
            return entry.contentType.displayName
        }
    }
}

private struct ClipboardSummaryMetadataPanel: View {
    let entry: ClipboardHistorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metadataRow("Source") {
                sourceValueView
            }
            metadataRow("Content type") {
                metadataValueText(contentTypeLabel)
            }
            metadataRow("Captured") {
                metadataValueText(entry.capturedAt.formatted(date: .numeric, time: .shortened))
            }
            metadataRow("Characters") {
                metadataValueText("\(entry.plainText?.count ?? 0)")
            }
            metadataRow("Words") {
                metadataValueText("\(entry.plainText?.split { $0.isWhitespace || $0.isNewline }.count ?? 0)")
            }
        }
        .padding(.vertical, ClipboardHistoryLayout.metadataVerticalPadding)
    }

    private func metadataRow<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                value()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(.secondary)

                value()
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, ClipboardHistoryLayout.outerHorizontalPadding + 8)
        .padding(.vertical, ClipboardHistoryLayout.metadataRowVerticalPadding)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.horizontal, ClipboardHistoryLayout.outerHorizontalPadding + 8)
        }
    }

    @ViewBuilder
    private var sourceValueView: some View {
        if let icon = sourceApplicationIcon {
            HStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(entry.sourceAppName)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            metadataValueText(entry.sourceAppName)
        }
    }

    private func metadataValueText(_ value: String) -> some View {
        Text(value)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .multilineTextAlignment(.trailing)
    }

    private var sourceApplicationIcon: NSImage? {
        guard let bundleIdentifier = entry.sourceAppBundleIdentifier,
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private var contentTypeLabel: String {
        switch entry.contentType {
        case .text:
            return "Text (Formatted)"
        default:
            return entry.contentType.displayName
        }
    }
}
