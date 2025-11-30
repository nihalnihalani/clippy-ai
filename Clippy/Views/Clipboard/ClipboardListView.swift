import SwiftUI
import SwiftData

struct ClipboardListView: View {
    @Binding var selectedItem: Item?
    var category: NavigationCategory?
    var searchText: String
    
    @Query private var items: [Item]
    
    init(selectedItem: Binding<Item?>, category: NavigationCategory?, searchText: String) {
        _selectedItem = selectedItem
        self.category = category
        self.searchText = searchText
        
        let isFavorite = category == .favorites
        let search = searchText
        
        // Construct predicate based on category and search text
        // Note: Handling optionals in Predicates can be tricky. simplified for robustness.
        
        if search.isEmpty {
            if isFavorite {
                _items = Query(filter: #Predicate<Item> { item in
                    item.isFavorite
                }, sort: \.timestamp, order: .reverse)
            } else {
                _items = Query(sort: \.timestamp, order: .reverse)
            }
        } else {
            if isFavorite {
                _items = Query(filter: #Predicate<Item> { item in
                    item.isFavorite && item.content.contains(search)
                }, sort: \.timestamp, order: .reverse)
            } else {
                _items = Query(filter: #Predicate<Item> { item in
                    item.content.contains(search)
                }, sort: \.timestamp, order: .reverse)
            }
        }
    }
    
    var body: some View {
        List(selection: $selectedItem) {
            // Section by date could be done here if we fetched all and grouped
            // For now, flat list as per basic requirements, maybe section later if requested
            ForEach(items) { item in
                ClipboardItemRow(item: item)
                    .tag(item)
            }
        }
        .listStyle(.inset)
        .navigationTitle(category?.rawValue ?? "Clipboard")
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
                Text(item.content)
                    .font(.system(.body))
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
