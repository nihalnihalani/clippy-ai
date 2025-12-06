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
        ZStack {
            // 1. Ambient Background Glow
            GeometryReader { proxy in
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 400, height: 400)
                    .blur(radius: 100)
                    .offset(x: -100, y: -100) // Top left glow
                
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 300, height: 300)
                    .blur(radius: 80)
                    .offset(x: proxy.size.width - 100, y: proxy.size.height - 100) // Bottom right glow
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.title ?? "Untitled")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        
                        HStack(spacing: 6) {
                            if let appName = item.appName {
                                Image(systemName: "app.fill")
                                Text(appName)
                            }
                            Text("·")
                            Text(item.timestamp, format: .dateTime.day().month().hour().minute())
                        }
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                    
                    // Main Content
                    if item.contentType == "image", let imagePath = item.imagePath {
                        AsyncImageLoader(imagePath: imagePath)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                            .padding(.horizontal, 20)
                    } else {
                        // Read-only TextEditor with transparent background
                        Text(item.content)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.9))
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.clear) // Transparent to let blur show through
                            .textSelection(.enabled)
                    }
                    
                    // Tags (Flow Layout)
                    if !item.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TAGS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)
                            
                            FlowLayout(spacing: 8) {
                                ForEach(item.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.15))
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(.white.opacity(0.2), lineWidth: 0.5)
                                        )
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    
                    Spacer(minLength: 80) // Space for floating bar
                }
            }
            // Floating Action Bar (Bottom Right)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 16) {
                    Button(action: {
                        item.isFavorite.toggle()
                    }) {
                        Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(item.isFavorite ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                    
                    Divider()
                        .frame(height: 16)
                    
                    Button(action: copyContentWithFeedback) {
                        Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(showCopiedFeedback ? .green : .primary)
                    }
                    .buttonStyle(.plain)
                    
                    Divider()
                        .frame(height: 16)
                    
                    Button(role: .destructive, action: deleteItem) {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                )
                .padding(24)
            }
        }
        .background(.ultraThinMaterial) // Glass background for entire detail view
        .ignoresSafeArea()
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
