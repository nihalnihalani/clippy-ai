import Foundation
import SwiftUI
import SwiftData

/// SessionViewModel: Manages AI processing state and input mode logic.
/// Extracted from ContentView to enforce MVVM pattern.
@MainActor
class SessionViewModel: ObservableObject {
    // MARK: - Input Mode
    
    enum InputMode: Equatable {
        case none
        case textCapture    // Option+X
        case voiceCapture   // Option+Space
        case visionCapture  // Option+V
    }
    
    @Published var activeInputMode: InputMode = .none
    @Published var isProcessingAnswer: Bool = false
    @Published var isRecordingVoice: Bool = false
    @Published var lastCapturedText: String = ""
    
    // Track when thinking state started (for minimum display time)
    private var thinkingStartTime: Date?
    
    // MARK: - Dependencies (injected)
    
    weak var container: AppDependencyContainer?
    var allItems: [Item] = []  // Updated by ContentView
    var elevenLabsService: ElevenLabsService?
    
    private var clipboardMonitor: ClipboardMonitor? { container?.clipboardMonitor }
    private var clippy: Clippy? { container?.clippy }
    private var clippyController: ClippyWindowController? { container?.clippyController }
    private var textCaptureService: TextCaptureService? { container?.textCaptureService }
    private var visionParser: VisionScreenParser? { container?.visionParser }
    private var localAIService: LocalAIService? { container?.localAIService }
    private var geminiService: GeminiService? { container?.geminiService }
    private var audioRecorder: AudioRecorder? { container?.audioRecorder }
    
    // MARK: - Selected AI Service
    
    @Published var selectedAIService: AIServiceType = .local {
        didSet {
            UserDefaults.standard.set(selectedAIService.rawValue, forKey: "SelectedAIService")
        }
    }
    
    init() {
        // Load stored AI service selection
        if let savedServiceString = UserDefaults.standard.string(forKey: "SelectedAIService"),
           let savedService = AIServiceType(rawValue: savedServiceString) {
            selectedAIService = savedService
        }
    }
    
    // MARK: - State Reset
    
    func resetInputState() {
        if textCaptureService?.isCapturing == true {
            textCaptureService?.stopCapturing()
        }
        
        if isRecordingVoice {
            isRecordingVoice = false
            _ = audioRecorder?.stopRecording()
        }
        
        if activeInputMode != .none {
            clippyController?.hide()
        }
        
        activeInputMode = .none
        isProcessingAnswer = false
        thinkingStartTime = nil
    }
    
    // MARK: - Text Capture (Option+X)
    
    func handleTextCaptureTrigger() {
        print("\n⌨️ [SessionViewModel] Text capture hotkey triggered (Option+X)")
        
        if activeInputMode == .textCapture {
            // Second press: Stop capturing and process
            if textCaptureService?.isCapturing == true {
                clippyController?.setState(.thinking)
                thinkingStartTime = Date()
                textCaptureService?.stopCapturing()
            } else {
                resetInputState()
            }
        } else {
            // Start text capture mode
            resetInputState()
            activeInputMode = .textCapture
            
            clippyController?.setState(.idle)
            textCaptureService?.startCapturing(
                onTypingDetected: { [weak self] in
                    self?.clippyController?.setState(.writing)
                },
                onComplete: { [weak self] capturedText in
                    self?.lastCapturedText = capturedText
                    self?.processCapturedText(capturedText)
                }
            )
        }
    }
    
    // MARK: - Voice Capture (Option+Space)
    
    func toggleVoiceRecording() {
        print("\n🎙️ [SessionViewModel] Voice capture hotkey triggered (Option+Space)")
        
        if activeInputMode == .voiceCapture {
            // Second press: Stop recording and process
            if isRecordingVoice {
                isRecordingVoice = false
                clippyController?.setState(.thinking)
                
                guard let url = audioRecorder?.stopRecording() else {
                    resetInputState()
                    return
                }
                
                guard let service = elevenLabsService else {
                    clippyController?.setState(.error, message: "ElevenLabs API Key missing! 🔑")
                    return
                }
                
                Task {
                    do {
                        let text = try await service.transcribe(audioFileURL: url)
                        if !text.isEmpty {
                            processCapturedText(text)
                        } else {
                            clippyController?.setState(.idle, message: "I didn't catch that 👂")
                            activeInputMode = .none
                        }
                    } catch {
                        print("Voice Error: \(error.localizedDescription)")
                        clippyController?.setState(.error, message: "Couldn't hear you 🙉")
                        activeInputMode = .none
                    }
                }
            } else {
                resetInputState()
            }
        } else {
            // Start voice capture mode
            resetInputState()
            activeInputMode = .voiceCapture
            
            if elevenLabsService == nil {
                clippyController?.setState(.idle, message: "Set ElevenLabs API Key in Settings ⚙️")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    if self?.activeInputMode == .voiceCapture {
                        self?.resetInputState()
                    }
                }
                return
            }
            
            isRecordingVoice = true
            _ = audioRecorder?.startRecording()
            clippyController?.setState(.idle, message: "Listening... 🎙️")
        }
    }
    
    // MARK: - Vision Capture (Option+V)
    
    func handleVisionHotkeyTrigger() {
        print("\n👁️ [SessionViewModel] Vision hotkey triggered (Option+V)")
        
        resetInputState()
        activeInputMode = .visionCapture
        
        clippyController?.setState(.thinking, message: "Capturing screen... 📸")
        
        visionParser?.parseCurrentScreen { [weak self] result in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                switch result {
                case .success(let parsedContent):
                    print("✅ Vision parsing successful!")
                    if !parsedContent.fullText.isEmpty {
                        if self.selectedAIService == .local, let imageData = parsedContent.imageData {
                            self.clippyController?.setState(.thinking, message: "Analyzing image... 🧠")
                            
                            Task {
                                let base64Image = imageData.base64EncodedString()
                                if let description = await self.localAIService?.generateVisionDescription(base64Image: base64Image) {
                                    await MainActor.run {
                                        self.saveVisionContent(description, originalText: parsedContent.fullText)
                                        self.clippyController?.setState(.done, message: "Image analyzed! ✨")
                                    }
                                } else {
                                    await MainActor.run {
                                        self.saveVisionContent(parsedContent.fullText)
                                        self.clippyController?.setState(.done, message: "Saved text ⚠️")
                                    }
                                }
                            }
                        } else {
                            self.saveVisionContent(parsedContent.fullText)
                            self.clippyController?.setState(.done, message: "Saved \(parsedContent.fullText.count) chars! ✅")
                        }
                    } else {
                        self.clippyController?.setState(.error, message: "No text found 👀")
                    }
                    
                case .failure(let error):
                    print("❌ Vision parsing failed: \(error)")
                    if case VisionParserError.screenCaptureFailed = error {
                        self.clippyController?.setState(.error, message: "Need Screen Recording permission 🔐")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        self.clippyController?.setState(.error, message: "Vision failed")
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.activeInputMode == .visionCapture {
                        self.activeInputMode = .none
                    }
                }
            }
        }
    }
    
    // MARK: - Process Captured Text
    
    func processCapturedText(_ capturedText: String) {
        print("\n🎯 [SessionViewModel] Processing captured text...")
        isProcessingAnswer = true
        
        if thinkingStartTime == nil {
            thinkingStartTime = Date()
        }
        clippyController?.setState(.thinking)
        
        Task {
            // 1. Semantic Search
            var relevantItems: [Item] = []
            
            if let clippy = clippy {
                let searchResults = await clippy.search(query: capturedText, limit: 30)
                let foundVectorIds = Set(searchResults.map { $0.0 })
                
                if !foundVectorIds.isEmpty {
                    let itemsWithIDs = allItems.filter { item in
                        guard let vid = item.vectorId else { return false }
                        return foundVectorIds.contains(vid)
                    }
                    
                    relevantItems = searchResults.compactMap { (id, _) in
                        itemsWithIDs.first(where: { $0.vectorId == id })
                    }
                }
            }
            
            // 2. Fallback to recent items
            if relevantItems.count < 5 {
                let recentItems = Array(allItems.prefix(5))
                for item in recentItems where !relevantItems.contains(where: { $0.timestamp == item.timestamp }) {
                    relevantItems.append(item)
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
            print("🧠 [SessionViewModel] RAG Context: \(relevantItems.count) items")
            
            // 4. Generate Answer
            let answer: String?
            let imageIndex: Int?
            
            switch selectedAIService {
            case .gemini:
                let simpleContext = relevantItems.map { ($0.content, $0.tags) }
                (answer, imageIndex) = await geminiService?.generateAnswerWithImageDetection(
                    question: capturedText,
                    clipboardContext: simpleContext,
                    appName: clipboardMonitor?.currentAppName ?? "Unknown"
                ) ?? (nil, nil)
                
            case .local:
                var fullAnswer = ""
                do {
                    if let stream = localAIService?.generateAnswerStream(
                        question: capturedText,
                        clipboardContext: clipboardContext,
                        appName: clipboardMonitor?.currentAppName ?? "Unknown"
                    ) {
                        for try await token in stream {
                            fullAnswer += token
                            let preview = fullAnswer.suffix(50).replacingOccurrences(of: "\n", with: " ")
                            clippyController?.setState(.writing, message: "...\(preview)")
                        }
                    }
                    answer = fullAnswer
                } catch {
                    print("❌ Streaming Error: \(error)")
                    answer = nil
                }
                imageIndex = nil
            }
            
            await MainActor.run {
                handleAIResponse(answer: answer, imageIndex: imageIndex, contextItems: relevantItems)
            }
        }
    }
    
    // MARK: - Handle AI Response
    
    private func handleAIResponse(answer: String?, imageIndex: Int?, contextItems: [Item]) {
        let elapsed = Date().timeIntervalSince(thinkingStartTime ?? Date())
        let remainingDelay = max(0, 3.0 - elapsed)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay) { [weak self] in
            guard let self = self else { return }
            
            self.isProcessingAnswer = false
            self.thinkingStartTime = nil
            
            self.clippyController?.setState(.done)
            
            if let imageIndex = imageIndex, imageIndex > 0, imageIndex <= contextItems.count {
                let item = contextItems[imageIndex - 1]
                if item.contentType == "image", let imagePath = item.imagePath {
                    ClipboardService.shared.copyImageToClipboard(imagePath: imagePath)
                    self.textCaptureService?.replaceCapturedTextWithAnswer("")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.simulatePaste()
                        self.clippyController?.setState(.done, message: "Image pasted! 🖼️")
                    }
                }
            } else if let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
                if self.activeInputMode == .textCapture {
                    self.textCaptureService?.replaceCapturedTextWithAnswer(answer)
                } else {
                    self.textCaptureService?.insertTextAtCursor(answer)
                }
                self.clippyController?.setState(.done, message: "Answer ready! 🎉")
            } else {
                self.clippyController?.setState(.idle, message: "No relevant answer 📋")
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.activeInputMode == .textCapture || self.activeInputMode == .voiceCapture {
                    self.activeInputMode = .none
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func saveVisionContent(_ text: String, originalText: String? = nil) {
        guard let repository = container?.repository else { return }
        
        let contentToSave = originalText != nil
            ? "Image Description:\n\(text)\n\nExtracted Text:\n\(originalText!)"
            : text
        
        Task {
            do {
                _ = try await repository.saveItem(
                    content: contentToSave,
                    appName: clipboardMonitor?.currentAppName ?? "Unknown",
                    contentType: "vision-parsed",
                    timestamp: Date(),
                    tags: [],
                    vectorId: nil,
                    imagePath: nil,
                    title: nil
                )
                print("💾 [SessionViewModel] Vision content saved")
            } catch {
                print("❌ [SessionViewModel] Failed to save vision: \(error)")
            }
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
    
    // MARK: - Legacy Hotkey Handler
    
    func handleHotkeyTrigger() {
        print("\n🔥 [SessionViewModel] Hotkey triggered (Option+S)")
        resetInputState()
    }
}
