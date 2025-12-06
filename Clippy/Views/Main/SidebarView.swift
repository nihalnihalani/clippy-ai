import SwiftUI
import SwiftData

enum NavigationCategory: String, CaseIterable, Identifiable {
    case allItems = "All Items"
    case favorites = "Favorites"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .allItems: return "clock.arrow.circlepath"
        case .favorites: return "heart.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationCategory?
    @Binding var selectedAIService: AIServiceType
    @ObservedObject var clippyController: ClippyWindowController
    @Binding var showSettings: Bool
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var container: AppDependencyContainer
    @State private var showClearConfirmation: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(NavigationCategory.allCases) { category in
                        NavigationLink(value: category) {
                            Label(category.rawValue, systemImage: category.iconName)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(SidebarListStyle())
            
            Divider()
            
            VStack(spacing: 16) {
                // Keyboard Shortcuts Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("SHORTCUTS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        KeyboardShortcutHint(keys: "⌥X", description: "Ask Clippy")
                        KeyboardShortcutHint(keys: "⌥Space", description: "Voice input")
                        KeyboardShortcutHint(keys: "⌥V", description: "Screen OCR")
                        KeyboardShortcutHint(keys: "ESC", description: "Dismiss")
                    }
                }
                
                Divider()
                
                // AI Service Selector
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AI SERVICE")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Configure API Keys")
                    }
                    
                    Picker("AI Service", selection: $selectedAIService) {
                        ForEach(AIServiceType.allCases, id: \.self) { service in
                            Text(service.rawValue).tag(service)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                
                // Assistant Toggle
                HStack {
                    Label("Assistant", systemImage: "pawprint.fill")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Toggle("", isOn: $clippyController.followTextInput)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                
                Divider()
                
                // Maintenance Section
                VStack(spacing: 8) {
                    Button(action: reindexSearch) {
                        HStack {
                            Image(systemName: "arrow.clockwise.circle")
                            Text("Re-index Search")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(role: .destructive, action: { showClearConfirmation = true }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear All History")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial)
        }
        .confirmationDialog(
            "Clear All Clipboard History?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                clearAllHistory()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete all clipboard items. This action cannot be undone.")
        }
    }
    
    private func clearAllHistory() {
        guard let repository = container.repository else { return }
        
        Task {
            do {
                // Fetch all items and delete them
                let descriptor = FetchDescriptor<Item>()
                let items = try modelContext.fetch(descriptor)
                
                for item in items {
                    // Use repository to ensure consistent deletion (Files + Vector + Data)
                    try await repository.deleteItem(item)
                }
                
                print("🗑️ [SidebarView] Cleared all \(items.count) clipboard items")
            } catch {
                print("❌ [SidebarView] Failed to clear history: \(error)")
            }
        }
    }
    
    private func reindexSearch() {
        Task {
            do {
                print("🔄 [SidebarView] Starting re-indexing...")
                let descriptor = FetchDescriptor<Item>()
                let items = try modelContext.fetch(descriptor)
                
                let documents = items.compactMap { item -> (UUID, String)? in
                    guard let vid = item.vectorId else { return nil }
                    let embeddingText = (item.title != nil && !item.title!.isEmpty) ? "\(item.title!)\n\n\(item.content)" : item.content
                    return (vid, embeddingText)
                }
                
                if !documents.isEmpty {
                    await container.clippy.addDocuments(items: documents)
                    print("✅ [SidebarView] Re-indexed \(documents.count) items")
                } else {
                    print("⚠️ [SidebarView] No items to re-index")
                }
            } catch {
                print("❌ [SidebarView] Failed to re-index: \(error)")
            }
        }
    }
}

// MARK: - Keyboard Shortcut Hint View

struct KeyboardShortcutHint: View {
    let keys: String
    let description: String
    
    var body: some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
}
