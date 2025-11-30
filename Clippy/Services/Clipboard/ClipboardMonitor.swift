import Foundation
import AppKit
import SwiftData
import ApplicationServices

@MainActor
class ClipboardMonitor: ObservableObject {
    @Published var currentAppName: String = "Unknown"
    @Published var currentWindowTitle: String = ""
    @Published var clipboardContent: String = ""
    @Published var isMonitoring: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    @Published var permissionStatusMessage: String = "Checking permissions..."
    @Published var accessibilityContext: String = ""
    
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private var modelContext: ModelContext?
    private var clippy: Clippy?
    private var geminiService: GeminiService?
    
    func startMonitoring(modelContext: ModelContext, clippy: Clippy, geminiService: GeminiService? = nil) {
        self.modelContext = modelContext
        self.clippy = clippy
        self.geminiService = geminiService
        
        // Check accessibility permission (for context features), but do not gate clipboard monitoring on it
        checkAccessibilityPermission()
        self.isMonitoring = true
        permissionStatusMessage = hasAccessibilityPermission
            ? "Accessibility permission granted"
            : "Limited mode: grant Accessibility for richer context"
        
        // Get initial clipboard state and sync changeCount WITHOUT processing existing content
        updateCurrentApp()
        
        // Initialize lastChangeCount to current clipboard state to avoid processing existing content on startup
        // This prevents re-tagging items that are already in the database when the app launches
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount
        
        // Update displayed clipboard content but don't save it
        if let string = pasteboard.string(forType: .string) {
            clipboardContent = string
        }
        
        // Don't call checkClipboard() here - it will be called by the timer only when clipboard actually changes
        
        // Start monitoring timer regardless of AX status
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                self.updateCurrentApp()
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
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)
        
        DispatchQueue.main.async {
            self.hasAccessibilityPermission = accessEnabled
            if accessEnabled {
                self.permissionStatusMessage = "Accessibility permission granted!"
                // Restart monitoring if we have model context
                if let modelContext = self.modelContext, let clippy = self.clippy {
                    self.startMonitoring(
                        modelContext: modelContext,
                        clippy: clippy,
                        geminiService: self.geminiService
                    )
                }
            } else {
                self.permissionStatusMessage = "Permission denied. Please enable in System Settings > Privacy & Security > Accessibility"
            }
        }
    }
    
    func checkAccessibilityPermission() {
        let accessEnabled = AXIsProcessTrusted()
        hasAccessibilityPermission = accessEnabled
        
        if accessEnabled {
            permissionStatusMessage = "Accessibility permission granted"
        } else {
            permissionStatusMessage = "Accessibility permission required"
        }
    }
    
    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func updateCurrentApp() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            currentAppName = "Unknown"
            currentWindowTitle = ""
            accessibilityContext = hasAccessibilityPermission ? "" : "Accessibility permission not granted."
            return
        }
        currentAppName = frontmostApp.localizedName ?? "Unknown App"
        if hasAccessibilityPermission {
            currentWindowTitle = getActiveWindowTitle() ?? ""
            accessibilityContext = buildAccessibilityContext(for: frontmostApp)
        } else {
            currentWindowTitle = frontmostApp.localizedName ?? ""
            accessibilityContext = "Accessibility permission not granted."
        }
    }
    
    private func getActiveWindowTitle() -> String? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        
        let pid = frontmostApp.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        
        var window: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        
        guard result == .success, let windowElement = window else { return nil }
        
        var title: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXTitleAttribute as CFString, &title)
        
        if titleResult == .success, let windowTitle = title as? String {
            return windowTitle
        }
        
        return nil
    }

    private func buildAccessibilityContext(for appInfo: NSRunningApplication) -> String {
        let pid = appInfo.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard windowResult == .success, let windowElement = focusedWindow else {
            return ""
        }
        var focusedUIElement: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedUIElement)
        var snapshotLines: [String] = []
        snapshotLines.append("App: \(currentAppName)")
        if let title = try? (windowElement as! AXUIElement).attributeString(for: kAXTitleAttribute as CFString), !title.isEmpty {
            snapshotLines.append("Window: \(title)")
        }
        // Collect static labels for quick context (first draw)
        let staticSummary = collectStaticTexts(from: windowElement as! AXUIElement, limit: 6)
        if !staticSummary.isEmpty {
            snapshotLines.append("Static Content: \(staticSummary)")
        }
        if let focused = focusedUIElement {
            snapshotLines.append("Focused Element:")
            var seenFocused = Set<String>()
            snapshotLines.append(contentsOf: describe(element: focused as! AXUIElement, depth: 1, maxDepth: 2, siblingsLimit: 4, dedupe: &seenFocused))
        }
        snapshotLines.append("Visible Elements:")
        var seen = Set<String>()
        snapshotLines.append(contentsOf: describe(element: windowElement as! AXUIElement, depth: 1, maxDepth: 2, siblingsLimit: 8, dedupe: &seen))
        return snapshotLines.joined(separator: "\n")
    }

    private func collectStaticTexts(from root: AXUIElement, limit: Int) -> String {
        var queue: [AXUIElement] = [root]
        var collected: [String] = []
        var visited = Set<AXUIElementHash>()
        while !queue.isEmpty && collected.count < limit {
            let element = queue.removeFirst()
            let hash = AXUIElementHash(element)
            guard !visited.contains(hash) else { continue }
            visited.insert(hash)
            if let value = try? element.attributeString(for: kAXValueAttribute as CFString), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                if collected.count >= limit { break }
            } else if let title = try? element.attributeString(for: kAXTitleAttribute as CFString), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected.append(title.trimmingCharacters(in: .whitespacesAndNewlines))
                if collected.count >= limit { break }
            }
            queue.append(contentsOf: element.attributeArray(for: kAXChildrenAttribute as CFString, limit: nil))
        }
        return collected.joined(separator: " • ")
    }
    
    /// Build rich context for semantic search
    func getRichContext() -> String {
        var contextParts: [String] = []
        
        // App name
        if !currentAppName.isEmpty && currentAppName != "Unknown" {
            contextParts.append("App: \(currentAppName)")
        }
        
        // Window title (can be very informative)
        if !currentWindowTitle.isEmpty {
            contextParts.append("Window: \(currentWindowTitle)")
        }
        
        // Recent clipboard content (for context continuity)
        if !clipboardContent.isEmpty && clipboardContent.count < 200 {
            contextParts.append("Recent: \(clipboardContent.prefix(100))")
        }
        if hasAccessibilityPermission {
            let axSummary = accessibilityContext
                .split(separator: "\n")
                .prefix(6)
                .joined(separator: " ")
            if !axSummary.isEmpty {
                contextParts.append("Context: \(axSummary.prefix(300))")
            }
        }
        
        // Time of day context
        let hour = Calendar.current.component(.hour, from: Date())
        let timeContext = switch hour {
        case 5..<12: "morning work"
        case 12..<17: "afternoon work"
        case 17..<22: "evening work"
        default: "late night work"
        }
        contextParts.append(timeContext)
        
        return contextParts.joined(separator: " | ")
    }
    
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
    
    private func getImagesDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let imagesDir = appSupport.appendingPathComponent("Clippy/Images")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        
        return imagesDir
    }
    
    private func saveImageItem(imageData: Data) {
        guard let modelContext = modelContext else { return }
        
        print("💾 [ClipboardMonitor] Saving new image item...")
        print("   Size: \(imageData.count) bytes")
        print("   App: \(currentAppName)")
        
        // Convert image to PNG format (Gemini only accepts PNG, JPEG, GIF, WebP)
        guard let nsImage = NSImage(data: imageData),
              let pngData = nsImage.pngData() else {
            print("   ❌ Failed to convert image to PNG format")
            return
        }
        
        print("   ✅ Converted to PNG: \(pngData.count) bytes")
        
        // 1. Save image to disk
        let filename = "\(UUID().uuidString).png"
        let imageURL = getImagesDirectory().appendingPathComponent(filename)
        
        do {
            try pngData.write(to: imageURL)
            print("   ✅ Image saved to disk: \(filename)")
        } catch {
            print("   ❌ Failed to save image to disk: \(error)")
            return
        }
        
        // 2. Analyze image with Gemini Vision (async)
        Task {
            let description = await geminiService?.analyzeImage(imageData: pngData) ?? "[Image]"
            
            print("   📝 Image description: \(description)")
            
            // 3. Create item with description as searchable content
            let newItem = Item(
                timestamp: Date(),
                content: description,
                appName: currentAppName.isEmpty ? nil : currentAppName,
                contentType: "image",
                imagePath: filename
            )
            
            // 4. Generate embeddings from description for search
            let vectorId = UUID()
            newItem.vectorId = vectorId
            
            modelContext.insert(newItem)
            
            do {
                try modelContext.save()
                print("   ✅ Image item saved to database with description")
                
                // 5. Store embedding for semantic search
                if let clippy = clippy {
                    await clippy.addDocument(vectorId: vectorId, text: description)
                    print("   ✅ Image embedding stored for search")
                }
            } catch {
                print("   ❌ Failed to save image item: \(error)")
            }
        }
    }
    
    private func saveClipboardItem(content: String) {
        guard let modelContext = modelContext else { return }
        
        // Filter out empty or whitespace-only content
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty {
            print("⚠️ [ClipboardMonitor] Skipping empty clipboard content")
            return
        }
        
        // Filter out very short content (likely noise)
        if trimmedContent.count < 3 {
            print("⚠️ [ClipboardMonitor] Skipping very short content: '\(trimmedContent)'")
            return
        }
        
        // Filter out debug log output (emojis and common log patterns)
        let debugPatterns = ["⌨️", "🎯", "✅", "❌", "📤", "📡", "📄", "💾", "🏷️", "🤖", "🛑", "🔄"]
        let containsDebugEmoji = debugPatterns.contains { trimmedContent.contains($0) }
        
        let logPatterns = ["[HotkeyManager]", "[ContentView]", "[TextCaptureService]", "[GeminiService]", "[ClipboardMonitor]", "[EmbeddingService]"]
        let containsLogPattern = logPatterns.contains { trimmedContent.contains($0) }
        
        if containsDebugEmoji || containsLogPattern {
            print("⚠️ [ClipboardMonitor] Skipping debug log output")
            return
        }
        
        // ✅ Deduplication: Check if exact same content already exists
        let fetchDescriptor = FetchDescriptor<Item>(
            predicate: #Predicate<Item> { item in
                item.content == content
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        
        do {
            let existingItems = try modelContext.fetch(fetchDescriptor)
            if let mostRecent = existingItems.first {
                print("⚠️ [ClipboardMonitor] Skipping duplicate content")
                print("   Content: \(trimmedContent.prefix(50))...")
                print("   Already exists from: \(mostRecent.timestamp.formatted())")
                return
            }
        } catch {
            print("⚠️ [ClipboardMonitor] Failed to check for duplicates: \(error)")
            // Continue saving even if duplicate check fails
        }
        
        print("💾 [ClipboardMonitor] Saving new clipboard item...")
        print("   Content: \(trimmedContent.prefix(50))...")
        print("   App: \(currentAppName)")
        
        let newItem = Item(
            timestamp: Date(),
            content: content,
            appName: currentAppName.isEmpty ? nil : currentAppName,
            contentType: "text"
        )
        // Generate vectorId and store on the item
        let vectorId = UUID()
        newItem.vectorId = vectorId
        
        modelContext.insert(newItem)
        
        do {
            try modelContext.save()
            print("   ✅ Item saved to database with vectorId: \(vectorId)")
            
            // Store embedding asynchronously
            if let clippy = clippy {
                Task {
                    await clippy.addDocument(vectorId: vectorId, text: content)
                }
            }
            
            // Generate tags asynchronously (non-blocking)
            if let geminiService = geminiService {
                Task {
                    let tags = await geminiService.generateTags(
                        content: content,
                        appName: currentAppName.isEmpty ? nil : currentAppName,
                        context: hasAccessibilityPermission ? accessibilityContext : nil
                    )
                    
                    // Update item with tags
                    if !tags.isEmpty {
                        newItem.tags = tags
                        try? modelContext.save()
                        print("   🏷️  Tags stored: \(tags)")
                    }
                }
            }
        } catch {
            print("   ❌ Failed to save clipboard item: \(error)")
        }
    }
}

private extension AXUIElement {
    func attributeString(for attribute: CFString) throws -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, attribute, &value)
        if result == .success, let str = value as? String {
            return str
        }
        throw NSError(domain: "AXError", code: Int(result.rawValue), userInfo: [NSLocalizedDescriptionKey: "Accessibility error: \(result)"])
    }
    
    func attributeArray(for attribute: CFString, limit: Int? = nil) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, attribute, &value)
        guard result == .success, let arr = value as? [AXUIElement] else { return [] }
        if let limit, limit >= 0 {
            return Array(arr.prefix(limit))
        }
        return arr
    }
    
    func roleDescription() -> String {
        (try? attributeString(for: kAXRoleDescriptionAttribute as CFString)) ??
        (try? attributeString(for: kAXRoleAttribute as CFString)) ?? ""
    }
    
    func valueDescription() -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, kAXValueAttribute as CFString, &value)
        if result == .success {
            if let str = value as? String { return str }
            if let num = value as? NSNumber { return num.stringValue }
        }
        return ""
    }
}

private func describe(element: AXUIElement, depth: Int, maxDepth: Int, siblingsLimit: Int, dedupe: inout Set<String>) -> [String] {
    guard depth <= maxDepth else { return [] }
    let indent = String(repeating: "  ", count: depth)
    var lines: [String] = []

    let role = element.roleDescription()
    let title = (try? element.attributeString(for: kAXTitleAttribute as CFString)) ?? ""
    let value = element.valueDescription()
    let identifier = [role, title, value].joined(separator: "|")

    if !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !dedupe.contains(identifier) {
        dedupe.insert(identifier)
        let summary = [role, title, value]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        if !summary.isEmpty {
            lines.append("\(indent)• \(summary)")
        }
    }

    if depth == maxDepth { return lines }

    let children = element.attributeArray(for: kAXChildrenAttribute as CFString, limit: siblingsLimit)
    for child in children {
        lines.append(contentsOf: describe(element: child, depth: depth + 1, maxDepth: maxDepth, siblingsLimit: siblingsLimit, dedupe: &dedupe))
    }

    return lines
}

private struct AXUIElementHash: Hashable {
    private let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element as CFTypeRef))
    }
    
    static func == (lhs: AXUIElementHash, rhs: AXUIElementHash) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

// MARK: - NSImage PNG Conversion Extension
extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }
}
