import SwiftUI
import SwiftData

enum AIServiceType: String, CaseIterable {
    case gemini = "Gemini"
    case local = "Local AI"
    
    var description: String {
        switch self {
        case .gemini:
            return "Gemini 2.5 Flash (Cloud)"
        case .local:
            return "Local Qwen3-4b (On-device)"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var container: AppDependencyContainer
    
    // Derived properties for cleaner access (optional, but helps avoid massive find/replace)
    private var clipboardMonitor: ClipboardMonitor { container.clipboardMonitor }
    private var clippy: Clippy { container.clippy }
    private var hotkeyManager: HotkeyManager { container.hotkeyManager }
    private var visionParser: VisionScreenParser { container.visionParser }
    private var textCaptureService: TextCaptureService { container.textCaptureService }
    private var clippyController: ClippyWindowController { container.clippyController }
    private var localAIService: LocalAIService { container.localAIService }
    // GeminiService is currently a @State in ContentView, but moved to container. 
    // We'll use the container one, but we need to verify if we need to observe it.
    private var geminiService: GeminiService { container.geminiService }
    private var audioRecorder: AudioRecorder { container.audioRecorder }

    // Constants/State
    @State private var elevenLabsService: ElevenLabsService?
    @State private var isRecordingVoice = false
    
    // Navigation State
    @State private var selectedCategory: NavigationCategory? = .allItems
    @State private var selectedItems: Set<PersistentIdentifier> = []
    @State private var searchText: String = ""
    @State private var showSettings: Bool = false
    @State private var selectedAIService: AIServiceType = .local // Default to Local
    
    // AI Processing State
    @State private var isProcessingAnswer: Bool = false
    @State private var lastCapturedText: String = ""
    @State private var thinkingStartTime: Date? // Track when thinking state started
    
    // Items Query for context (we still need this for AI context even if list has its own query)
    @Query(sort: \Item.timestamp, order: .reverse) private var allItems: [Item]

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selectedCategory,
                selectedAIService: $selectedAIService,
                clippyController: clippyController,
                showSettings: $showSettings
            )
        } content: {
            ClipboardListView(
                selectedItems: $selectedItems,
                category: selectedCategory ?? .allItems,
                searchText: $searchText
            )
        } detail: {
            // Show first selected item in detail view
            if let firstSelectedId = selectedItems.first,
               let item = allItems.first(where: { $0.id == firstSelectedId }) {
                ClipboardDetailView(item: item)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Select an item to view details")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                apiKey: Binding(
                    get: { getStoredAPIKey() },
                    set: { saveAPIKey($0) }
                ),
                elevenLabsKey: Binding(
                    get: { UserDefaults.standard.string(forKey: "ElevenLabs_API_Key") ?? "" },
                    set: { 
                        UserDefaults.standard.set($0, forKey: "ElevenLabs_API_Key")
                        if !$0.isEmpty {
                            elevenLabsService = ElevenLabsService(apiKey: $0)
                        } else {
                            elevenLabsService = nil
                        }
                    }
                ),
                selectedService: $selectedAIService
            )
        }
        .onChange(of: selectedAIService) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "SelectedAIService")
        }
        .onChange(of: clipboardMonitor.hasAccessibilityPermission) { _, granted in
            if granted && !hotkeyManager.isListening {
                print("🔓 [ContentView] Permissions granted, restarting HotkeyManager...")
                startHotkeys()
            }
        }
        .onAppear {
            setupServices()
        }
        .onDisappear {
            clipboardMonitor.stopMonitoring()
            hotkeyManager.stopListening()
        }
    }
    
    // MARK: - Setup & Services
    
    private func setupServices() {
        // Load stored AI service selection
        if let savedServiceString = UserDefaults.standard.string(forKey: "SelectedAIService"),
           let savedService = AIServiceType(rawValue: savedServiceString) {
            selectedAIService = savedService
        }
        
        // Load stored API key
        let storedKey = getStoredAPIKey()
        if !storedKey.isEmpty {
            geminiService.updateApiKey(storedKey)
        }
        
        // Initialize ElevenLabs Service
        let elevenLabsKey = getStoredElevenLabsKey()
        if !elevenLabsKey.isEmpty {
            elevenLabsService = ElevenLabsService(apiKey: elevenLabsKey)
        }
        
        Task {
            // Initialize Vector DB
            await clippy.initialize()
        }
        
        // Start hotkeys on main thread (required for CGEvent tap)
        startHotkeys()
    }
    
    private func startHotkeys() {
        print("⌨️ [ContentView] Starting hotkey listener...")
        hotkeyManager.startListening(
            onTrigger: { handleHotkeyTrigger() },
            onVisionTrigger: { handleVisionHotkeyTrigger() },
            onTextCaptureTrigger: { handleTextCaptureTrigger() },
            onVoiceCaptureTrigger: { toggleVoiceRecording() }
        )
        print("⌨️ [ContentView] Hotkey listener started: \(hotkeyManager.isListening)")
    }
    
    // MARK: - Logic Handlers

    
    // MARK: - Input Mode Management
    
    enum InputMode {
        case none
        case textCapture // Option+X
        case voiceCapture // Option+Space
        case visionCapture // Option+V
    }
    
    @State private var activeInputMode: InputMode = .none
    
    private func resetInputState() {
        // Cancel text capture
        if textCaptureService.isCapturing {
            textCaptureService.stopCapturing()
        }
        
        // Cancel voice recording
        if isRecordingVoice {
            isRecordingVoice = false
            _ = audioRecorder.stopRecording()
        }
        
        // Reset UI state
        if activeInputMode != .none {
            // Only hide if we were actually doing something
            clippyController.hide()
        }
        
        activeInputMode = .none
        isProcessingAnswer = false
        thinkingStartTime = nil
    }
    
    private func handleHotkeyTrigger() {
        print("\n🔥 [ContentView] Hotkey triggered (Option+S)")
        // Legacy suggestions removed. This hotkey is currently free or can be reassigned.
        resetInputState()
    }
    
    private func handleVisionHotkeyTrigger() {
        print("\n👁️ [ContentView] Vision hotkey triggered (Option+V)")
        
        // Vision is a one-shot action, but we should still reset other modes
        resetInputState()
        activeInputMode = .visionCapture
        
        clippyController.setState(.thinking, message: "Capturing screen... 📸")
        
        visionParser.parseCurrentScreen { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let parsedContent):
                    print("✅ Vision parsing successful!")
                    print("   Extracted \(parsedContent.fullText.count) characters")
                    if !parsedContent.fullText.isEmpty {
                        // If we have image data and Local AI is selected, generate a description
                        if self.selectedAIService == .local, let imageData = parsedContent.imageData {
                            self.clippyController.setState(.thinking, message: "Analyzing image... 🧠")
                            
                            Task {
                                let base64Image = imageData.base64EncodedString()
                                if let description = await self.localAIService.generateVisionDescription(base64Image: base64Image) {
                                    await MainActor.run {
                                        self.saveVisionContent(description, originalText: parsedContent.fullText)
                                        self.clippyController.setState(.done, message: "Image analyzed! ✨")
                                    }
                                } else {
                                    await MainActor.run {
                                        self.saveVisionContent(parsedContent.fullText)
                                        self.clippyController.setState(.done, message: "Saved text (Vision failed) ⚠️")
                                    }
                                }
                            }
                        } else {
                            self.saveVisionContent(parsedContent.fullText)
                            self.clippyController.setState(.done, message: "Saved \(parsedContent.fullText.count) chars! ✅")
                        }
                    } else {
                        self.clippyController.setState(.error, message: "No text found 👀")
                    }
                case .failure(let error):
                    print("❌ Vision parsing failed: \(error.localizedDescription)")
                    
                    // Check if it's a permission error
                    if case VisionParserError.screenCaptureFailed = error {
                        self.clippyController.setState(.error, message: "Need Screen Recording permission 🔐")
                        // Open System Settings
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        self.clippyController.setState(.error, message: "Vision failed: \(error.localizedDescription)")
                    }
                }
                
                // Reset mode after short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.activeInputMode == .visionCapture {
                        self.activeInputMode = .none
                    }
                }
            }
        }
    }
    
    private func saveVisionContent(_ text: String, originalText: String? = nil) {
        guard let repository = container.repository else { return }
        
        // Deduplication check could be done here, but simplified for brevity
        let contentToSave = originalText != nil ? "Image Description:\n\(text)\n\nExtracted Text:\n\(originalText!)" : text
        
        Task {
            do {
                _ = try await repository.saveItem(
                    content: contentToSave,
                    appName: clipboardMonitor.currentAppName,
                    contentType: "vision-parsed",
                    timestamp: Date(),
                    tags: [],
                    vectorId: nil,
                    imagePath: nil,
                    title: nil
                )
                print("💾 [ContentView] Vision content saved via Repository")
            } catch {
                print("❌ [ContentView] Failed to save vision content: \(error)")
            }
        }
    }
    
    private func handleTextCaptureTrigger() {
        print("\n⌨️ [ContentView] Text capture hotkey triggered (Option+X)")
        
        if activeInputMode == .textCapture {
            // Second press: Stop capturing and start thinking
            if textCaptureService.isCapturing {
                clippyController.setState(.thinking)
                thinkingStartTime = Date() // Record when thinking started
                textCaptureService.stopCapturing()
                // Processing happens in onComplete callback
            } else {
                // Should not happen if state is consistent, but safe fallback
                resetInputState()
            }
        } else {
            // Switch to text capture mode
            resetInputState()
            activeInputMode = .textCapture
            
            clippyController.setState(.idle)
            textCaptureService.startCapturing(
                onTypingDetected: {
                    // Switch to writing state when user starts typing
                    self.clippyController.setState(.writing)
                },
                onComplete: { capturedText in
                    self.lastCapturedText = capturedText
                    self.processCapturedText(capturedText)
                }
            )
        }
    }
    
    private func processCapturedText(_ capturedText: String) {
        print("\n🎯 [ContentView] Processing captured text...")
        isProcessingAnswer = true
        
        // Ensure thinking state is set and time is recorded
        if thinkingStartTime == nil {
            thinkingStartTime = Date()
        }
        clippyController.setState(.thinking)
        
        Task {
            // 1. Semantic Search for Context
            var relevantItems: [Item] = []
            
            // Perform vector search
            let searchResults = await clippy.search(query: capturedText, limit: 30)
            let foundVectorIds = Set(searchResults.map { $0.0 })
            
            if !foundVectorIds.isEmpty {
                // Filter allItems for matching IDs
                // Note: Efficient enough for typical usage; huge DBs might need optimization
                let itemsWithIDs = allItems.filter { item in
                    guard let vid = item.vectorId else { return false }
                    return foundVectorIds.contains(vid)
                }
                
                // Sort by search score (re-order based on searchResults order)
                relevantItems = searchResults.compactMap { (id, _) in
                    itemsWithIDs.first(where: { $0.vectorId == id })
                }
            }
            
            // 2. Fallback / Supplement with Recent Items
            // If we have few results, add recent items to ensure we have recent context too
            if relevantItems.count < 5 {
                let recentItems = Array(allItems.prefix(5))
                for item in recentItems {
                    if !relevantItems.contains(where: { $0.timestamp == item.timestamp }) {
                        relevantItems.append(item)
                    }
                }
            }
            
            // 3. Build Context
            let clipboardContext: [RAGContextItem] = relevantItems.map { item in
                RAGContextItem(
                    content: item.content,
                    tags: item.tags,
                    type: item.contentType,
                    timestamp: item.timestamp,
                    title: item.title
                )
            }
            print("🧠 [ContentView] RAG Context: Using \(relevantItems.count) items (\(searchResults.count) from search)")

            let answer: String?
            let imageIndex: Int?
            
            switch selectedAIService {
            case .gemini:
                // Gemini service might need update or we keep it compatible with old struct if it uses a different one
                // For now, assuming GeminiService has its own signature or isn't used in Local mode
                 // Converting back to simple context for Gemini if needed, or update Gemini signature later.
                 // Since we are in .local mode usually, let's focus on that.
                 // Actually ContentView uses same logic. Let's assume GeminiService still takes [(String, [String])]
                 // We might need to simplify for Gemini if it hasn't been updated.
                 let simpleContext = relevantItems.map { ($0.content, $0.tags) }
                (answer, imageIndex) = await geminiService.generateAnswerWithImageDetection(
                    question: capturedText,
                    clipboardContext: simpleContext,
                    appName: clipboardMonitor.currentAppName
                )
            case .local:
                // Streaming Implementation for Local AI
                var fullAnswer = ""
                do {
                    let stream = localAIService.generateAnswerStream(
                        question: capturedText,
                        clipboardContext: clipboardContext,
                        appName: clipboardMonitor.currentAppName
                    )
                    
                    for try await token in stream {
                        fullAnswer += token
                        // UX: Show streaming text in Clippy bubble!
                        // Truncate to keep it fitting in the bubble (e.g. last 50 chars)
                        await MainActor.run {
                            let preview = fullAnswer.suffix(50).replacingOccurrences(of: "\n", with: " ")
                            self.clippyController.setState(.writing, message: "...\(preview)")
                        }
                    }
                    answer = fullAnswer
                } catch {
                    print("❌ Streaming Error: \(error)")
                    answer = nil // Fallback to handling nil below
                }
                imageIndex = nil
            }
            
            await MainActor.run {
                // Check for errors and get error message
                let errorMessage = geminiService.lastErrorMessage
                handleAIResponse(answer: answer, imageIndex: imageIndex, contextItems: relevantItems, errorMessage: errorMessage)
            }
        }
    }
    
    private func handleAIResponse(answer: String?, imageIndex: Int?, contextItems: [Item], errorMessage: String? = nil) {
        // Calculate how long we've been in thinking state
        let elapsed = Date().timeIntervalSince(thinkingStartTime ?? Date())
        let remainingDelay = max(0, 3.0 - elapsed) // Minimum 3 seconds of thinking
        
        print("🎯 [ContentView] AI response received. Elapsed: \(elapsed)s, Remaining delay: \(remainingDelay)s")
        
        // Delay transition to done state if needed to ensure minimum 3s thinking
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay) {
            self.isProcessingAnswer = false
            self.thinkingStartTime = nil // Reset thinking timer
            
            // Check if there was an error
            if let errorMessage = errorMessage {
                self.clippyController.setState(.error, message: "❌ \(errorMessage)")
                // Auto-hide after showing error
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.clippyController.hide()
                }
                return
            }
            
            // Transition to done state
            self.clippyController.setState(.done)
            
            if let imageIndex = imageIndex, imageIndex > 0, imageIndex <= contextItems.count {
                let item = contextItems[imageIndex - 1]
                if item.contentType == "image", let imagePath = item.imagePath {
                    ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
                    
                    // Delete original item logic via Repository
                    if let repository = self.container.repository {
                        Task {
                            try? await repository.deleteItem(item)
                        }
                    }
                    
                    self.textCaptureService.replaceCapturedTextWithAnswer("")
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.simulatePaste()
                        self.clippyController.setState(.done, message: "Image pasted! 🖼️")
                    }
                } else {
                    self.clippyController.setState(.idle, message: "That's not an image 🤔")
                }
            } else if let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
                // Handle based on input mode
                if self.activeInputMode == .textCapture {
                    // For text capture: replace captured text with answer
                    self.textCaptureService.replaceCapturedTextWithAnswer(answer)
                    self.clippyController.setState(.done, message: "Answer ready! 🎉")
                } else if self.activeInputMode == .voiceCapture {
                    // For voice: insert answer at current cursor position
                    self.textCaptureService.insertTextAtCursor(answer)
                    self.clippyController.setState(.done, message: "Answer ready! 🎉")
                } else {
                    // Fallback: insert at cursor
                    self.textCaptureService.insertTextAtCursor(answer)
                    self.clippyController.setState(.done, message: "Answer ready! 🎉")
                }
            } else {
                self.clippyController.setState(.idle, message: "Question not relevant to clipboard 📋")
            }
            
            // Reset input mode after processing
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                // Only reset if still in the same mode (user hasn't started something else)
                if self.activeInputMode == .textCapture || self.activeInputMode == .voiceCapture {
                    self.activeInputMode = .none
                }
            }
        }
    }
    
    private func toggleVoiceRecording() {
        print("\n🎙️ [ContentView] Voice capture hotkey triggered (Option+Space)")
        
        if activeInputMode == .voiceCapture {
            // Second press: Stop Recording & Process
            if isRecordingVoice {
                isRecordingVoice = false
                clippyController.setState(.thinking) // Dog looks like it's thinking
                
                guard let url = audioRecorder.stopRecording() else { 
                    resetInputState()
                    return 
                }
                
                guard let service = elevenLabsService else {
                    clippyController.setState(.error, message: "ElevenLabs API Key missing! 🔑")
                    // Don't reset state immediately so user sees message
                    return
                }
                
                Task {
                    do {
                        // 1. Transcribe via ElevenLabs
                        let text = try await service.transcribe(audioFileURL: url)
                        
                        // 2. Feed into existing logic (same as typing)
                        await MainActor.run {
                            if !text.isEmpty {
                                self.processCapturedText(text)
                            } else {
                                self.clippyController.setState(.idle, message: "I didn't catch that 👂")
                                self.activeInputMode = .none
                            }
                        }
                    } catch {
                        await MainActor.run {
                            print("Voice Error: \(error.localizedDescription)")
                            self.clippyController.setState(.error, message: "Couldn't hear you 🙉")
                            self.activeInputMode = .none
                        }
                    }
                }
            } else {
                resetInputState()
            }
        } else {
            // Switch to Voice Capture Mode
            resetInputState()
            activeInputMode = .voiceCapture
            
            // Check if service is available before starting
            if elevenLabsService == nil {
                clippyController.setState(.idle, message: "Set ElevenLabs API Key in Settings ⚙️")
                // Reset mode after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self.activeInputMode == .voiceCapture {
                        self.resetInputState()
                    }
                }
                return
            }
            
            isRecordingVoice = true
            _ = audioRecorder.startRecording()
            clippyController.setState(.idle, message: "Listening... 🎙️")
        }
    }
    
    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyDown?.flags = .maskCommand
        vKeyUp?.flags = .maskCommand
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
    }
    
    // MARK: - API Key Helpers
    
    private func saveAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "Gemini_API_Key")
        geminiService.updateApiKey(key)
        
        // No need to restart monitoring as dependencies are injected by reference
        // and GeminiService handles its own key state.
    }
    
    private func getStoredAPIKey() -> String {
        // 1. Check process environment
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty { return envKey }
        
        // 2. Check UserDefaults
        if let stored = UserDefaults.standard.string(forKey: "Gemini_API_Key"), !stored.isEmpty {
            return stored
        }
        
        // 3. Check local .env file manually (Fallback for development)
        let envPath = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env")
        if let content = try? String(contentsOf: envPath, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                if line.starts(with: "GEMINI_API_KEY=") {
                    return line.replacingOccurrences(of: "GEMINI_API_KEY=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        return ""
    }
    
    private func getStoredElevenLabsKey() -> String {
        // 1. Check process environment
        if let envKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !envKey.isEmpty { return envKey }
        
        // 2. Check UserDefaults
        if let stored = UserDefaults.standard.string(forKey: "ElevenLabs_API_Key"), !stored.isEmpty {
            return stored
        }
        
        // 3. Check local .env file manually (Fallback for development)
        let envPath = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env")
        if let content = try? String(contentsOf: envPath, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                if line.starts(with: "ELEVENLABS_API_KEY=") {
                    return line.replacingOccurrences(of: "ELEVENLABS_API_KEY=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        return ""
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var apiKey: String
    @Binding var elevenLabsKey: String
    @Binding var selectedService: AIServiceType
    
    @State private var tempGeminiKey: String = ""
    @State private var tempElevenLabsKey: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.bold)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Gemini API Key")
                            .font(.headline)
                        
                        SecureField("Enter Gemini API key...", text: $tempGeminiKey)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { tempGeminiKey = apiKey }
                        
                        Text("Required for Gemini services. Keys are stored locally.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ElevenLabs API Key")
                            .font(.headline)
                        
                        SecureField("Enter ElevenLabs API key...", text: $tempElevenLabsKey)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { tempElevenLabsKey = elevenLabsKey }
                        
                        Text("Required for voice input (Option+Space). Keys are stored locally.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    apiKey = tempGeminiKey
                    elevenLabsKey = tempElevenLabsKey
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 450, height: 350)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
