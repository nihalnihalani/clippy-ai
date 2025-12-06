import Foundation
import SwiftData

@MainActor
class AppDependencyContainer: ObservableObject {
    // Core Services
    let clippy: Clippy
    let clipboardMonitor: ClipboardMonitor
    let visionParser: VisionScreenParser
    let hotkeyManager: HotkeyManager
    let textCaptureService: TextCaptureService
    let clippyController: ClippyWindowController
    
    // AI Services
    let localAIService: LocalAIService
    let geminiService: GeminiService
    let audioRecorder: AudioRecorder
    
    // Data Layer
    var repository: ClipboardRepository?
    
    init() {
        print("🏗️ [AppDependencyContainer] Initializing services...")
        
        // 1. Initialize Independent Services
        self.clippy = Clippy()
        self.visionParser = VisionScreenParser()
        self.hotkeyManager = HotkeyManager()
        self.clippyController = ClippyWindowController()
        self.audioRecorder = AudioRecorder()
        self.localAIService = LocalAIService()
        self.geminiService = GeminiService(apiKey: UserDefaults.standard.string(forKey: "Gemini_API_Key") ?? "")
        self.textCaptureService = TextCaptureService()
        
        // 2. Initialize Dependent Services
        self.clipboardMonitor = ClipboardMonitor()
        
        print("✅ [AppDependencyContainer] Services initialized.")
    }
    
    func inject(modelContext: ModelContext) {
        print("💉 [AppDependencyContainer] Injecting ModelContext and Cross-Service Dependencies...")
        
        // Initialize Repository
        self.repository = SwiftDataClipboardRepository(modelContext: modelContext, vectorService: clippy)
        
        // Inject dependencies into ClipboardMonitor
        if let repo = self.repository {
            clipboardMonitor.startMonitoring(
                repository: repo,
                geminiService: geminiService,
                localAIService: localAIService,
                visionParser: visionParser
            )
        }
        
        // Inject dependencies into TextCaptureService
        textCaptureService.setDependencies(
            clippyController: clippyController,
            clipboardMonitor: clipboardMonitor
        )
    }
}
