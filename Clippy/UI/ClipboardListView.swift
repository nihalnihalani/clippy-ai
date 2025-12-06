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
    
    var body: some View {
        VStack(spacing: 0) {
            // "World Class" Glass Search Bar
            // Search bar moved to toolbar
            
            List(selection: $selectedItems) {
                if searchText.isEmpty {
                    // Normal List View
                    ForEach(filteredItems) { item in
                        ClipboardItemRow(item: item, isSelected: selectedItems.contains(item.persistentModelID))
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
                            ClipboardItemRow(item: item, isSelected: selectedItems.contains(item.persistentModelID))
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
                let results = await container.clippy.search(query: newValue, limit: 20)
                
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
        if let category = category, category == .favorites {
            return allItems.filter { $0.isFavorite }
        }
        return allItems
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
        ClipboardService.shared.copyTextToClipboard(item.content)
    }
    
    private func deleteItem(_ item: Item) {
        modelContext.delete(item)
        // Note: For complete consistency, we should also delete from Vector DB using ClipboardRepository if available,
        // but modelContext deletion is propagated via NotificationCenter if setup, or we rely on next app launch sync.
        // For now, this suffices for UI.
        Task {
             try? await container.clippy.deleteDocument(vectorId: item.vectorId ?? UUID())
        }
    }
}


// MARK: - Clipboard Item Row

// MARK: - Clipboard Item Row

struct ClipboardItemRow: View {
    let item: Item
    let isSelected: Bool
    @State private var actions: [ClipboardAction] = []
    @State private var isHovering = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Gradient Icon
            ZStack {
                Circle()
                    .fill(iconGradient)
                    .frame(width: 38, height: 38)
                    .shadow(color: iconColor.opacity(0.3), radius: 4, x: 0, y: 2)
                
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Title
                Text(item.title ?? item.content)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                // Metadata
                HStack(spacing: 6) {
                    Text(timeAgo(from: item.timestamp))
                    
                    if let appName = item.appName {
                        Text("·")
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
        .onHover { hover in
            isHovering = hover
        }
        .onAppear {
            if actions.isEmpty && item.contentType == "text" {
                DispatchQueue.global(qos: .background).async {
                    let detected = ActionDetector.shared.detectActions(in: item.content)
                    DispatchQueue.main.async { actions = detected }
                }
            }
        }
    }
    
    private var iconName: String {
        switch item.contentType {
        case "image": return "photo"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }
    
    private var iconColor: Color {
        switch item.contentType {
        case "image": return .blue
        case "code": return .purple
        default: return .blue
        }
    }
    
    private var iconGradient: LinearGradient {
        switch item.contentType {
        case "image":
            return LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "code":
            return LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    
    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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

