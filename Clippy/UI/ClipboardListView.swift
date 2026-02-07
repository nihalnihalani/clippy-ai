import SwiftUI
import SwiftData

struct ClipboardListView: View {
    @Binding var selectedItems: Set<PersistentIdentifier>
    var category: NavigationCategory?
    @Binding var searchText: String
    
    @EnvironmentObject var container: AppDependencyContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Item.timestamp, order: .reverse) private var allItems: [Item]
    
    @State private var searchResults: [Item] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var lastClickedItemId: PersistentIdentifier? // For shift-click range selection
    @State private var copiedItemId: PersistentIdentifier?
    @State private var keyboardIndex: Int = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // "World Class" Glass Search Bar
            // Search bar moved to toolbar
            
            List(selection: $selectedItems) {
                if searchText.isEmpty {
                    // Normal List View
                    ForEach(filteredItems) { item in
                        clipboardRow(for: item)
                    }
                } else {
                    // Search Results View
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView("Searching...")
                                .scaleEffect(0.8)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    } else if searchResults.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(searchResults) { item in
                            clipboardRow(for: item)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(category?.rawValue ?? "Clipboard")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    GlassSearchBar(searchText: $searchText)
                        .frame(width: 250) // Slightly smaller for right alignment
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onKeyPress(.escape) {
                if !selectedItems.isEmpty {
                    selectedItems.removeAll()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.upArrow) {
                let items = currentItems
                if keyboardIndex > 0 {
                    keyboardIndex -= 1
                    selectItemAtIndex(keyboardIndex, in: items)
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                let items = currentItems
                if keyboardIndex < items.count - 1 {
                    keyboardIndex += 1
                    selectItemAtIndex(keyboardIndex, in: items)
                }
                return .handled
            }
            .onKeyPress(.return) {
                let items = currentItems
                if keyboardIndex >= 0, keyboardIndex < items.count {
                    copyToClipboard(items[keyboardIndex])
                }
                return .handled
            }
            .onKeyPress(.delete, modifiers: .command) {
                let items = currentItems
                if keyboardIndex >= 0, keyboardIndex < items.count {
                    deleteItem(items[keyboardIndex])
                }
                return .handled
            }
            .onKeyPress("d", modifiers: .command) {
                let items = currentItems
                if keyboardIndex >= 0, keyboardIndex < items.count {
                    items[keyboardIndex].isFavorite.toggle()
                }
                return .handled
            }
        }
        .navigationTitle(category?.rawValue ?? "Clipboard")
        .onChange(of: searchText) { _, newValue in
            // Cancel previous task
            searchTask?.cancel()
            
            guard !newValue.isEmpty else {
                searchResults = []
                isSearching = false
                return
            }
            
            isSearching = true
            
            searchTask = Task {
                // Debounce
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                
                if Task.isCancelled { return }
                
                // 1. Perform semantic search
                let results = await container.vectorSearch.search(query: newValue, limit: 20)
                
                if Task.isCancelled { return }
                
                // 2. Map IDs back to Items
                let ids = results.map { $0.0 }
                
                await MainActor.run {
                    if Task.isCancelled { return }
                    
                    // Efficiently find items in current loaded list
                    let foundItems = allItems.filter { ids.contains($0.vectorId ?? UUID()) }
                    
                    // Sort by the order returned from search (relevance)
                    self.searchResults = ids.compactMap { id in
                        foundItems.first(where: { $0.vectorId == id })
                    }
                    
                    self.isSearching = false
                }
            }
        }
    }
    
    // Filter items based on category (when not searching)
    private var filteredItems: [Item] {
        guard let category = category else { return allItems }
        switch category {
        case .allItems: return allItems
        case .favorites: return allItems.filter { $0.isFavorite }
        case .code: return allItems.filter { SidebarView.isCodeContent($0) }
        case .urls: return allItems.filter { SidebarView.isURLContent($0) }
        case .images: return allItems.filter { $0.contentType == "image" }
        case .sensitive: return allItems.filter { $0.isSensitive }
        }
    }

    // Active items list (search results or filtered)
    private var currentItems: [Item] {
        searchText.isEmpty ? filteredItems : searchResults
    }

    private func selectItemAtIndex(_ index: Int, in items: [Item]) {
        guard index >= 0, index < items.count else { return }
        selectedItems = [items[index].persistentModelID]
    }

    // MARK: - Shared Row Builder

    @ViewBuilder
    private func clipboardRow(for item: Item) -> some View {
        ClipboardItemRow(
            item: item,
            isSelected: selectedItems.contains(item.persistentModelID),
            isCopied: copiedItemId == item.persistentModelID
        )
            .tag(item)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button {
                    copyToClipboard(item)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Divider()

                Button {
                    performTransform(item, instruction: "Fix grammar and spelling.")
                } label: {
                    Label("Fix Grammar", systemImage: "text.badge.checkmark")
                }

                Button {
                    performTransform(item, instruction: "Summarize this text in one sentence.")
                } label: {
                    Label("Summarize", systemImage: "text.quote")
                }

                Button {
                    performTransform(item, instruction: "Convert this to valid JSON.")
                } label: {
                    Label("To JSON", systemImage: "curlybraces")
                }

                Divider()

                Button(role: .destructive) {
                    deleteItem(item)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    // MARK: - Helper Methods

    private func performTransform(_ item: Item, instruction: String) {
        Task {
            guard let result = await container.localAIService.transformText(text: item.content, instruction: instruction) else { return }
            await MainActor.run {
                ClipboardService.shared.copyTextToClipboard(result)
            }
        }
    }
    
    private func copyToClipboard(_ item: Item) {
        container.clipboardMonitor.skipNextClipboardChange = true

        if item.contentType == "image", let imagePath = item.imagePath {
            ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
        } else {
            ClipboardService.shared.copyTextToClipboard(item.content)
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            copiedItemId = item.persistentModelID
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                if copiedItemId == item.persistentModelID {
                    copiedItemId = nil
                }
            }
        }
    }
    
    private func deleteItem(_ item: Item) {
        modelContext.delete(item)
        // Note: For complete consistency, we should also delete from Vector DB using ClipboardRepository if available,
        // but modelContext deletion is propagated via NotificationCenter if setup, or we rely on next app launch sync.
        // For now, this suffices for UI.
        Task {
             try? await container.vectorSearch.deleteDocument(vectorId: item.vectorId ?? UUID())
        }
    }
}


// MARK: - Clipboard Item Row

// MARK: - Clipboard Item Row

struct ClipboardItemRow: View {
    let item: Item
    let isSelected: Bool
    var isCopied: Bool = false
    @State private var actions: [ClipboardAction] = []
    @State private var isHovering = false

    private var isCode: Bool { SidebarView.isCodeContent(item) }
    private var isURL: Bool { SidebarView.isURLContent(item) }

    private var urlDomain: String? {
        guard isURL else { return nil }
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed.components(separatedBy: "\n").first ?? trimmed)?.host
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon or image thumbnail
            if item.contentType == "image", let imagePath = item.imagePath {
                let imageURL = ClipboardService.shared.getImagesDirectory().appendingPathComponent(imagePath)
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Circle().fill(iconGradient)
                        Image(systemName: "photo")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color.blue.opacity(0.2), radius: 4, x: 0, y: 2)
            } else {
                ZStack {
                    Circle()
                        .fill(isCopied ? LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing) : richIconGradient)
                        .frame(width: 38, height: 38)
                        .shadow(color: (isCopied ? Color.green : richIconColor).opacity(0.3), radius: 4, x: 0, y: 2)

                    Image(systemName: isCopied ? "checkmark" : richIconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                // Title with content-aware font
                if item.isSensitive {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text("Sensitive content")
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundColor(.orange)
                    }
                } else if isCopied {
                    Text("Copied!")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(.green)
                } else if isCode {
                    Text(item.title ?? String(item.content.prefix(80)).replacingOccurrences(of: "\n", with: " "))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundColor(.purple)
                        .lineLimit(1)
                } else if isURL, let domain = urlDomain {
                    Text(domain)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(.teal)
                        .lineLimit(1)
                } else {
                    Text(item.title ?? item.content)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(item.content.count < 100 ? 3 : 1)
                }

                // Metadata
                HStack(spacing: 6) {
                    Text(timeAgo(from: item.timestamp))

                    if let appName = item.appName {
                        Text("\u{00B7}")
                        Text(appName)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)

                // Tags (minimal)
                if !item.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.tags.prefix(2), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(.white.opacity(0.2), lineWidth: 0.5)
                                )
                        }
                        if item.tags.count > 2 {
                            Text("+\(item.tags.count - 2)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .padding(.top, 2)
                }

                // Detected Actions (shown on hover or selection)
                if !actions.isEmpty && (isHovering || isSelected) {
                    HStack(spacing: 6) {
                        ForEach(actions) { action in
                            Button(action: { action.perform() }) {
                                HStack(spacing: 3) {
                                    Image(systemName: action.iconName)
                                        .font(.system(size: 9))
                                    Text(action.label)
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 2)
                }
            }

            Spacer()

            // Favorite indicator
            if item.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(4)
            }
        }
        .modifier(ClipboardItemRowStyle(isSelected: isSelected, isHovering: isHovering))
        .draggable(item.content)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hover
            }
        }
        .onAppear {
            if actions.isEmpty && item.contentType == "text" {
                DispatchQueue.global(qos: .background).async {
                    let detected = ActionDetector.shared.detectActions(in: item.content)
                    DispatchQueue.main.async { actions = detected }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue(item.isFavorite ? "Favorite" : "")
        .accessibilityHint("Double click to copy. Use context menu for more actions.")
    }

    private var accessibilityDescription: String {
        let type = item.contentType == "image" ? "Image" : "Text"
        let content = item.isSensitive ? "Sensitive content" : String((item.title ?? item.content).prefix(60))
        let app = item.appName ?? "Unknown app"
        return "\(type) from \(app): \(content)"
    }

    private var richIconName: String {
        if item.isSensitive { return "lock.fill" }
        if isCode { return "chevron.left.forwardslash.chevron.right" }
        if isURL { return "link" }
        switch item.contentType {
        case "image": return "photo"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }

    private var richIconColor: Color {
        if item.isSensitive { return .orange }
        if isCode { return .purple }
        if isURL { return .teal }
        switch item.contentType {
        case "image": return .blue
        case "code": return .purple
        default: return .blue
        }
    }

    private var richIconGradient: LinearGradient {
        if item.isSensitive {
            return LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if isCode {
            return LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if isURL {
            return LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        switch item.contentType {
        case "image":
            return LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "code":
            return LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // Legacy references for backward compat
    private var iconName: String { richIconName }
    private var iconColor: Color { richIconColor }
    private var iconGradient: LinearGradient { richIconGradient }
    
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func timeAgo(from date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

struct GlassSearchBar: View {
    @Binding var searchText: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Ask your clipboard...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
            
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.3), lineWidth: 1)
        )
        // .padding(16) removed for toolbar usage
    }
}

// MARK: - Row Style Modifier
struct ClipboardItemRowStyle: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool
    
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(isHovering ? .regularMaterial : .thinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(isSelected ? 0.5 : 0.1), lineWidth: 1)
            )
            // .scaleEffect removed per user request
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
            .shadow(color: Color.black.opacity(isHovering ? 0.1 : 0.05), radius: isHovering ? 8 : 2, x: 0, y: isHovering ? 4 : 1)
    }
}

