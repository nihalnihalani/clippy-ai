import SwiftUI
import SwiftData

struct ClipboardDetailView: View {
    @Bindable var item: Item
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var container: AppDependencyContainer
    @State private var newTagInput: String = ""
    @State private var isEditingTags: Bool = false
    @State private var showCopiedFeedback: Bool = false
    @State private var selectedTag: String? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header / Title
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title ?? item.content)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    
                    HStack {
                        if let appName = item.appName {
                            Label(appName, systemImage: "app")
                        }
                        Text("•")
                        Text(item.timestamp, format: .dateTime.day().month().hour().minute())
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Main Content Display
                VStack(alignment: .leading, spacing: 12) {
                    Text("CONTENT")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    
                    if item.contentType == "image", let imagePath = item.imagePath {
                        AsyncImageLoader(imagePath: imagePath)
                            .cornerRadius(8)
                            .frame(maxHeight: 500)
                            .shadow(radius: 2)
                        
                        // Show description below image
                        Text(item.content)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(12)
                            .textSelection(.enabled)
                    } else {
                        Text(item.content)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(12)
                            .textSelection(.enabled)
                    }
                    
                    // Prominent Copy Button
                    Button(action: copyContentWithFeedback) {
                        HStack {
                            Image(systemName: showCopiedFeedback ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                            Text(showCopiedFeedback ? "Copied!" : "Copy to Clipboard")
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(showCopiedFeedback ? Color.green : Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
                }
                
                // Tags Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("TAGS")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: { isEditingTags.toggle() }) {
                            Label(isEditingTags ? "Done" : "Edit", systemImage: isEditingTags ? "checkmark.circle" : "pencil.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    
                    FlowLayout(spacing: 8) {
                        ForEach(item.tags, id: \.self) { tag in
                            TagChipView(
                                tag: tag,
                                isSelected: selectedTag == tag,
                                isEditing: isEditingTags,
                                onSelect: { selectedTag = (selectedTag == tag) ? nil : tag },
                                onRemove: { removeTag(tag) }
                            )
                        }
                        
                        if isEditingTags {
                            HStack {
                                TextField("New tag", text: $newTagInput)
                                    .textFieldStyle(.plain)
                                    .frame(width: 80)
                                    .onSubmit { addTag() }
                                
                                Button(action: addTag) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                                .disabled(newTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(16)
                        }
                    }
                }
                
                Spacer()
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    item.isFavorite.toggle()
                }) {
                    Label("Favorite", systemImage: item.isFavorite ? "heart.fill" : "heart")
                        .foregroundColor(item.isFavorite ? .red : .primary)
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: copyContent) {
                    Label("Copy", systemImage: "doc.on.clipboard")
                }
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive, action: deleteItem) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .focusable()
        .onKeyPress(.escape) {
            if let tag = selectedTag {
                removeTag(tag)
                selectedTag = nil
                return .handled
            }
            return .ignored
        }
    }
    
    private func copyContent() {
        if item.contentType == "image", let imagePath = item.imagePath {
            ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
        } else {
            ClipboardService.shared.copyTextToClipboard(item.content)
        }
    }
    
    private func copyContentWithFeedback() {
        copyContent()
        
        // Show feedback
        withAnimation {
            showCopiedFeedback = true
        }
        
        // Reset after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopiedFeedback = false
            }
        }
    }
    
    private func deleteItem() {
        guard let repository = container.repository else { return }
        Task {
            try? await repository.deleteItem(item)
        }
    }
    
    private func addTag() {
        let trimmed = newTagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !item.tags.contains(trimmed) else {
            newTagInput = ""
            return
        }
        
        item.tags.append(trimmed)
        newTagInput = ""
    }
    
    private func removeTag(_ tag: String) {
        item.tags.removeAll { $0 == tag }
    }
}

// MARK: - Async Image Loader
/// Loads images on a background thread to prevent UI blocking
struct AsyncImageLoader: View {
    let imagePath: String
    @State private var loadedImage: NSImage?
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView()
                    .frame(height: 200)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .frame(height: 200)
            }
        }
        .onAppear {
            loadImageAsync()
        }
    }
    
    private func loadImageAsync() {
        Task.detached(priority: .userInitiated) {
            let image = ClipboardService.shared.loadImage(from: imagePath)
            await MainActor.run {
                self.loadedImage = image
                self.isLoading = false
            }
        }
    }
}

// MARK: - Tag Chip View
/// Reusable tag chip with selection and delete support
struct TagChipView: View {
    let tag: String
    let isSelected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.subheadline)
            
            if isEditing {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.blue.opacity(0.3) : Color.blue.opacity(0.1))
        .foregroundColor(.blue)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .onTapGesture(perform: onSelect)
    }
}
