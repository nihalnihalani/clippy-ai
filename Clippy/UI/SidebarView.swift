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
    @AppStorage("showSidebarShortcuts") private var showShortcuts: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(NavigationCategory.allCases) { category in
                        NavigationLink(value: category) {
                            Label(category.rawValue, systemImage: category.iconName)
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                }
            }
            .padding(.top, 44) // Clear traffic lights
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            
            // Bottom Panel
            VStack(spacing: 12) {
                // AI Service
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("AI")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Picker("", selection: $selectedAIService) {
                        ForEach(AIServiceType.allCases, id: \.self) { service in
                            Text(service.rawValue).tag(service)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                
                // Assistant
                HStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Assistant")
                        .font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: $clippyController.followTextInput)
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .labelsHidden()
                }
                
                Divider()
                    .opacity(0.5)
                
                // Shortcuts Row (Left Aligned)
                HStack {
                    DisclosureGroup("Shortcuts", isExpanded: $showShortcuts) {
                        VStack(alignment: .leading, spacing: 4) {
                            KeyboardShortcutHint(keys: "⌥X", description: "Ask")
                            KeyboardShortcutHint(keys: "⌥V", description: "OCR")
                            KeyboardShortcutHint(keys: "⌥␣", description: "Voice")
                        }
                        .padding(.top, 4)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    
                    Spacer()
                }
                
                // Actions Row (Buttons)
                HStack(spacing: 8) {
                    Button(action: reindexSearch) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .help("Re-index Search")
                    
                    Button(role: .destructive, action: { showClearConfirmation = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .help("Clear History")
                    
                    Spacer()
                }
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .ignoresSafeArea(edges: .top)
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
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
}
