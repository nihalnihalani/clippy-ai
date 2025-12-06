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
    private var repository: ClipboardRepository?
    private var geminiService: GeminiService?
    private var localAIService: LocalAIService?
    private var visionParser: VisionScreenParser?
    
    func startMonitoring(repository: ClipboardRepository, geminiService: GeminiService? = nil, localAIService: LocalAIService? = nil, visionParser: VisionScreenParser? = nil) {
        self.repository = repository
        self.geminiService = geminiService
        self.localAIService = localAIService
        self.visionParser = visionParser
        
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
                // Restart monitoring if we have repository
                if let repository = self.repository {
                    self.startMonitoring(
                        repository: repository,
                        geminiService: self.geminiService,
                        localAIService: self.localAIService,
                        visionParser: self.visionParser
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
            if currentAppName != "Unknown" { currentAppName = "Unknown" }
            if currentWindowTitle != "" { currentWindowTitle = "" }
            let newContext = hasAccessibilityPermission ? "" : "Accessibility permission not granted."
            if accessibilityContext != newContext { accessibilityContext = newContext }
            return
        }
        
        let newAppName = frontmostApp.localizedName ?? "Unknown App"
        if currentAppName != newAppName {
            currentAppName = newAppName
        }
        
        let newWindowTitle: String
        let newContext: String
        
        if hasAccessibilityPermission {
            newWindowTitle = getActiveWindowTitle() ?? ""
            newContext = buildAccessibilityContext(for: frontmostApp)
        } else {
            newWindowTitle = frontmostApp.localizedName ?? ""
            newContext = "Accessibility permission not granted."
        }
        
        if currentWindowTitle != newWindowTitle {
            currentWindowTitle = newWindowTitle
        }
        
        if accessibilityContext != newContext {
            accessibilityContext = newContext
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
        guard let repository = repository else { return }
        
        print("💾 [ClipboardMonitor] Saving new image item...")
        
        // Convert image to PNG format
        guard let nsImage = NSImage(data: imageData),
              let pngData = nsImage.pngData() else {
            print("   ❌ Failed to convert image to PNG format")
            return
        }
        
        // 1. FAST SAVE: Save image to disk
        let filename = "\(UUID().uuidString).png"
        let imageURL = getImagesDirectory().appendingPathComponent(filename)
        
        do {
            try pngData.write(to: imageURL)
        } catch {
            print("   ❌ Failed to save image to disk: \(error)")
            return
        }
        
        // 2. SAVE PLACEHOLDER: Insert item immediately so it appears in UI
        let vectorId = UUID()
        Task {
            do {
                let newItem = try await repository.saveItem(
                    content: "Analyzing image... 🖼️", // Temporary content
                    appName: currentAppName.isEmpty ? "Unknown" : currentAppName,
                    contentType: "image",
                    timestamp: Date(),
                    tags: [],
                    vectorId: vectorId,
                    imagePath: filename,
                    title: "Processing..."
                )
                print("   ✅ Image placeholder saved via Repository")
                
                // 3. ASYNC ENHANCE: Run Vision & Tagging
                // We pass the pngData to avoid reloading files
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
            
            // Vision Analysis
            if let localService = await self.localAIService {
                print("   🧠 [Async] Using Local Vision...")
                let base64Image = pngData.base64EncodedString()
                // Accessing visionParser needs main thread safely or valid access
                // For now, skipping screenText for simplicity or need to capture it BEFORE detach.
                // Re-architecture suggestion: capture screenText in main thread before calling saveImageItem?
                // For now, minimal regression: skip screen context in async path if complex, OR capture it early.
                
                if let localDesc = await localService.generateVisionDescription(base64Image: base64Image, screenText: nil) {
                    description = localDesc // Use raw desc for now or parse it
                    // Simple parsing logic duplicate from before...
                    // (Simplified for brevity, assuming LocalAIService returns raw text)
                    if localDesc.contains("Title:") {
                         let lines = localDesc.split(separator: "\n")
                         if let TitleLine = lines.first(where: { $0.hasPrefix("Title:") }) {
                             title = String(TitleLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                         }
                         description = localDesc // Store full desc
                    }
                }
            } else if let gemini = await self.geminiService {
                 print("   ✨ [Async] Using Gemini Vision...")
                 description = await gemini.analyzeImage(imageData: pngData) ?? "[Image]"
            }
            
            // Update Item Content & Title safely
            let finalDescription = description
            let finalTitle = title
            
            await MainActor.run {
                item.content = finalDescription
                item.title = finalTitle
            }
            
            // Update in DB (Re-vectorize)
            if let repo = await self.repository {
                try? await repo.updateItem(item)
                print("   ✅ Image analysis complete & updated.")
            }
            
            // Now run Tagging (re-use enhanceItem logic or call tags)
            // Can chain enhanceItem(item) here
            await self.enhanceItem(item)
        }
    }
    
    private func saveClipboardItem(content: String) {
        guard let repository = repository else { return }
        
        // Filter out empty or whitespace-only content
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty || trimmedContent.count < 3 {
             return
        }
        
        // Filter out debug/log content
        let debugPatterns = ["⌨️", "🎯", "✅", "❌", "📤", "📡", "📄", "💾", "🏷️", "🤖", "🛑", "🔄"]
        let logPatterns = ["[HotkeyManager]", "[ContentView]", "[TextCaptureService]", "[GeminiService]", "[ClipboardMonitor]", "[EmbeddingService]"]
        if debugPatterns.contains(where: { trimmedContent.contains($0) }) || logPatterns.contains(where: { trimmedContent.contains($0) }) {
            return
        }
        
        // ✅ Deduplication via Repository
        if repository.findDuplicate(content: content) != nil {
            print("⚠️ [ClipboardMonitor] Skipping duplicate content")
            return
        }
        
        print("💾 [ClipboardMonitor] Saving new clipboard item...")
        
        let vectorId = UUID()
        
        Task {
            do {
                // 1. FAST SAVE: Save text immediately
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
                print("   ✅ Item saved via Repository: \(vectorId)")
                
                // 2. ASYNC ENHANCE: Trigger AI processing in background
                enhanceItem(newItem)
                
            } catch {
                print("   ❌ Failed to save clipboard item: \(error)")
            }
        }
    }
    
    // Decoupled AI Processing
    private func enhanceItem(_ item: Item) {
        // 1. Extract values on Main Thread (Safe)
        let content = item.content
        let appName = item.appName
        
        // 2. Detach to background (simulated)
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            var tags: [String] = []
            
            // Note: Services are currently @MainActor, so we inevitably hop back.
            // Phase 2.2: We are decoupling, but we still need to respect MainActor isolation of the Service class.
            
            if let localService = await self.localAIService {
                // To avoid "async closure" error in MainActor.run, we use a Task or simply await properly.
                // If MainActor.run fails with async, we can use Task { @MainActor ... }.value
                let generatedTags = await Task { @MainActor in
                    await localService.generateTags(
                        content: content,
                        appName: appName,
                        context: nil
                    )
                }.value
                tags = generatedTags
            } else if let gemini = await self.geminiService {
                let generatedTags = await Task { @MainActor in
                    await gemini.generateTags(
                        content: content,
                        appName: appName,
                        context: nil
                    )
                }.value
                tags = generatedTags
            }
            
            if !tags.isEmpty {
                // 3. Update item safely on Main Thread
                if let repo = await self.repository {
                    await MainActor.run {
                        // Check if item is still valid/un-deleted before updating?
                        item.tags = tags
                        Task {
                            try? await repo.updateItem(item)
                            print("   🏷️  Tags updated via Repository: \(tags)")
                        }
                    }
                }
            }
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
