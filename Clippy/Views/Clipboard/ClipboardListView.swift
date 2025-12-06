import SwiftUI
import SwiftData

struct ClipboardListView: View {
    @Binding var selectedItem: Item?
    var category: NavigationCategory?
    var searchText: String
    
    @EnvironmentObject var container: AppDependencyContainer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Item.timestamp, order: .reverse) private var allItems: [Item]
    
    @State private var searchResults: [Item] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    
    var body: some View {
        List(selection: $selectedItem) {
            if searchText.isEmpty {
                // Normal List View
                ForEach(filteredItems) { item in
                    ClipboardItemRow(item: item)
                        .tag(item)
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
                } else if searchResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {

                    ForEach(searchResults) { item in
                        ClipboardItemRow(item: item)
                            .tag(item)
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
        .listStyle(.inset)
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
                    // Note: For very large datasets, we might need a direct fetch by ID
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

struct ClipboardItemRow: View {
    let item: Item
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon / Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 40, height: 40)
                
                if item.contentType == "image" {
                    Image(systemName: "photo")
                        .foregroundColor(.blue)
                } else if item.contentType == "code" {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundColor(.purple)
                } else {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                }
            }
            

            VStack(alignment: .leading, spacing: 4) {
                // Main Content Preview
                Text(item.title ?? item.content)
                    .font(item.title != nil ? .system(.body, design: .rounded).weight(.medium) : .system(.body))
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                HStack(spacing: 6) {
                    // Time
                    Text(timeAgo(from: item.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    // App Name
                    if let appName = item.appName {
                        Text("Copied from \(appName)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Action Buttons (Dynamic)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.self) { action in
                            Button(action: { action.perform() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: action.iconName)
                                    Text(action.label)
                                }
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }
                    }
                    .padding(.top, 2)
                }
                
                // Tags
                if !item.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(item.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                                    .foregroundColor(.secondary)
                            }
                            if item.tags.count > 3 {
                                Text("+\(item.tags.count - 3)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            // Lazy detection
            if actions.isEmpty && item.contentType == "text" {
                DispatchQueue.global(qos: .userInitiated).async {
                    let detected = ActionDetector.shared.detectActions(in: item.content)
                    DispatchQueue.main.async {
                        self.actions = detected
                    }
                }
            }
        }
    }
    
    @State private var actions: [ClipboardAction] = []
    
    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
