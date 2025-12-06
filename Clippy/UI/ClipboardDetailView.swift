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
            VStack(alignment: .leading, spacing: 20) {
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
                            .cornerRadius(12)
                            .frame(maxHeight: 500)
                            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                        
                        // Show description below image
                        Text(item.content)
                            .font(.body)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                            .cornerRadius(12)
                            .textSelection(.enabled)
                    } else {
                        Text(item.content)
                            .font(.system(.body, design: .monospaced))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
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
            .padding(20)
        }
        .background(.ultraThinMaterial)
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
        HStack(spacing: 6) {
            Image(systemName: "tag.fill")
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .white : .blue.opacity(0.8))
            
            Text(tag)
                .font(.system(.caption, weight: .medium))
            
            if isEditing {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                        .symbolEffect(.pulse, options: .repeating, isActive: isEditing)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue : Color.blue.opacity(0.12))
        )
        .foregroundColor(isSelected ? .white : .blue)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - FlowLayout Helper for Tags Display

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize
        var positions: [CGPoint]
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var positions: [CGPoint] = []
            var size: CGSize = .zero
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let subviewSize = subview.sizeThatFits(.unspecified)
                
                if currentX + subviewSize.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: currentX, y: currentY))
                currentX += subviewSize.width + spacing
                lineHeight = max(lineHeight, subviewSize.height)
                size.width = max(size.width, currentX - spacing)
                size.height = currentY + lineHeight
            }
            
            self.size = size
            self.positions = positions
        }
    }
}
