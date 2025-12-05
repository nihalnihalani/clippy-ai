import SwiftUI
import SwiftData

struct ClipboardListView: View {
    @Binding var selectedItem: Item?
    var category: NavigationCategory?
    var searchText: String
    
    @EnvironmentObject var clippy: Clippy
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Item.timestamp, order: .reverse) private var allItems: [Item]
    
    @State private var searchResults: [Item] = []
    @State private var isSearching = false
    
    var body: some View {
        List(selection: $selectedItem) {
            if searchText.isEmpty {
                // Normal List View
                ForEach(filteredItems) { item in
                    ClipboardItemRow(item: item)
                        .tag(item)
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
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(category?.rawValue ?? "Clipboard")
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
        }
    }
    
    // Filter items based on category (when not searching)
    private var filteredItems: [Item] {
        if let category = category, category == .favorites {
            return allItems.filter { $0.isFavorite }
        }
        return allItems
    }
    
    private func performSearch(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        
        isSearching = true
        
        Task {
            // 1. Perform semantic search
            let results = await clippy.search(query: query, limit: 20)
            
            // 2. Map IDs back to Items
            let ids = results.map { $0.0 }
            
            await MainActor.run {
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
    }
    
    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
