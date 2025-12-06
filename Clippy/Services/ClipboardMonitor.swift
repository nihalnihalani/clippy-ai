import Foundation
import AppKit
import SwiftData

/// ClipboardMonitor: Thin orchestrator for clipboard events.
/// Delegates context to ContextEngine, ingestion to Repository.
@MainActor
class ClipboardMonitor: ObservableObject {
    @Published var clipboardContent: String = ""
    @Published var isMonitoring: Bool = false
    
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var repository: ClipboardRepository?
    private var contextEngine: ContextEngine?
    private var geminiService: GeminiService?
    private var localAIService: LocalAIService?
    
    // MARK: - Computed Properties (delegated to ContextEngine)
    
    var currentAppName: String { contextEngine?.currentAppName ?? "Unknown" }
    var currentWindowTitle: String { contextEngine?.currentWindowTitle ?? "" }
    var hasAccessibilityPermission: Bool { contextEngine?.hasAccessibilityPermission ?? false }
    var accessibilityContext: String { contextEngine?.accessibilityContext ?? "" }
    
    var permissionStatusMessage: String {
        hasAccessibilityPermission
            ? "Accessibility permission granted"
            : "Limited mode: grant Accessibility for richer context"
    }
    
    // MARK: - Lifecycle
    
    func startMonitoring(
        repository: ClipboardRepository,
        contextEngine: ContextEngine,
        geminiService: GeminiService? = nil,
        localAIService: LocalAIService? = nil
    ) {
        self.repository = repository
        self.contextEngine = contextEngine
        self.geminiService = geminiService
        self.localAIService = localAIService
        
        // Initialize lastChangeCount to avoid processing existing content
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        
        if let string = pasteboard.string(forType: .string) {
            clipboardContent = string
        }
        
        isMonitoring = true
        
        // Start monitoring timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                self.contextEngine?.updateContext()
                self.checkClipboard()
            }
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }
    
    func requestAccessibilityPermission() {
        contextEngine?.requestAccessibilityPermission()
    }
    
    func openSystemPreferences() {
        contextEngine?.openSystemPreferences()
    }
    
    func getRichContext() -> String {
        contextEngine?.getRichContext(clipboardContent: clipboardContent) ?? ""
    }
    
    // MARK: - Clipboard Detection
    
    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        
        if currentChangeCount != lastChangeCount {
            lastChangeCount = currentChangeCount
            
            // Check for images first
            if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
                clipboardContent = "[Image]"
                saveImageItem(imageData: imageData)
            }
            // Then check for text
            else if let string = pasteboard.string(forType: .string) {
                clipboardContent = string
                saveClipboardItem(content: string)
            } else {
                clipboardContent = ""
            }
        }
    }
    
    // MARK: - Image Handling
    
    private func getImagesDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let imagesDir = appSupport.appendingPathComponent("Clippy/Images")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        return imagesDir
    }
    
    private func saveImageItem(imageData: Data) {
        guard let repository = repository else { return }
        
        print("💾 [ClipboardMonitor] Saving new image item...")
        
        guard let nsImage = NSImage(data: imageData),
              let pngData = nsImage.pngData() else {
            print("   ❌ Failed to convert image to PNG format")
            return
        }
        
        let filename = "\(UUID().uuidString).png"
        let imageURL = getImagesDirectory().appendingPathComponent(filename)
        
        do {
            try pngData.write(to: imageURL)
        } catch {
            print("   ❌ Failed to save image to disk: \(error)")
            return
        }
        
        let vectorId = UUID()
        Task {
            do {
                let newItem = try await repository.saveItem(
                    content: "Analyzing image... 🖼️",
                    appName: currentAppName.isEmpty ? "Unknown" : currentAppName,
                    contentType: "image",
                    timestamp: Date(),
                    tags: [],
                    vectorId: vectorId,
                    imagePath: filename,
                    title: "Processing..."
                )
                print("   ✅ Image placeholder saved")
                enhanceImageItem(newItem, pngData: pngData)
            } catch {
                print("   ❌ Failed to save image item: \(error)")
            }
        }
    }
    
    private func enhanceImageItem(_ item: Item, pngData: Data) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            var title: String?
            var description: String = "[Image]"
            
            if let localService = await self.localAIService {
                let base64Image = pngData.base64EncodedString()
                if let localDesc = await localService.generateVisionDescription(base64Image: base64Image, screenText: nil) {
                    description = localDesc
                    if localDesc.contains("Title:") {
                        let lines = localDesc.split(separator: "\n")
                        if let titleLine = lines.first(where: { $0.hasPrefix("Title:") }) {
                            title = String(titleLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            } else if let gemini = await self.geminiService {
                description = await gemini.analyzeImage(imageData: pngData) ?? "[Image]"
            }
            
            await MainActor.run {
                item.content = description
                item.title = title
            }
            
            if let repo = await self.repository {
                try? await repo.updateItem(item)
                print("   ✅ Image analysis complete")
            }
            
            await self.enhanceItem(item)
        }
    }
    
    // MARK: - Text Handling
    
    private func saveClipboardItem(content: String) {
        guard let repository = repository else { return }
        
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty || trimmedContent.count < 3 { return }
        
        // Filter debug content
        let debugPatterns = ["⌨️", "🎯", "✅", "❌", "📤", "📡", "📄", "💾", "🏷️", "🤖", "🛑", "🔄"]
        let logPatterns = ["[HotkeyManager]", "[ContentView]", "[TextCaptureService]", "[GeminiService]", "[ClipboardMonitor]", "[EmbeddingService]"]
        if debugPatterns.contains(where: { trimmedContent.contains($0) }) || logPatterns.contains(where: { trimmedContent.contains($0) }) {
            return
        }
        
        if repository.findDuplicate(content: content) != nil {
            print("⚠️ [ClipboardMonitor] Skipping duplicate content")
            return
        }
        
        print("💾 [ClipboardMonitor] Saving new clipboard item...")
        
        let vectorId = UUID()
        Task {
            do {
                let newItem = try await repository.saveItem(
                    content: content,
                    appName: currentAppName.isEmpty ? "Unknown" : currentAppName,
                    contentType: "text",
                    timestamp: Date(),
                    tags: [],
                    vectorId: vectorId,
                    imagePath: nil,
                    title: nil
                )
                print("   ✅ Item saved: \(vectorId)")
                enhanceItem(newItem)
            } catch {
                print("   ❌ Failed to save: \(error)")
            }
        }
    }
    
    // MARK: - AI Enhancement
    
    private func enhanceItem(_ item: Item) {
        let content = item.content
        let appName = item.appName
        
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            var tags: [String] = []
            
            if let localService = await self.localAIService {
                tags = await Task { @MainActor in
                    await localService.generateTags(content: content, appName: appName, context: nil)
                }.value
            } else if let gemini = await self.geminiService {
                tags = await Task { @MainActor in
                    await gemini.generateTags(content: content, appName: appName, context: nil)
                }.value
            }
            
            if !tags.isEmpty, let repo = await self.repository {
                await MainActor.run {
                    item.tags = tags
                    Task {
                        try? await repo.updateItem(item)
                        print("   🏷️ Tags updated: \(tags)")
                    }
                }
            }
        }
    }
}

// MARK: - NSImage PNG Extension

extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }
}

// MARK: - Clipboard Service (Copy/Paste Operations)

class ClipboardService {
    static let shared = ClipboardService()
    
    private init() {}
    
    func getImagesDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Clippy/Images")
    }
    
    func loadImage(from path: String) -> NSImage? {
        let imageURL = getImagesDirectory().appendingPathComponent(path)
        return NSImage(contentsOf: imageURL)
    }
    
    func copyImageToClipboard(imagePath: String) {
        let imageURL = getImagesDirectory().appendingPathComponent(imagePath)
        guard let nsImage = NSImage(contentsOf: imageURL) else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }
    
    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
