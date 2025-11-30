# Technical Report: Clippy

## 1. Executive Summary
Clippy is a macOS clipboard manager leveraging local and cloud AI to provide intelligent context-aware suggestions and semantic search. It uses `SwiftData` for persistence, `VecturaKit` for embeddings, and Accessibility APIs for context gathering.

## 2. System Architecture

### Core Components
- **ClipboardMonitor**: The central engine that monitors the system pasteboard. It uses `NSPasteboard` polling and Accessibility APIs (`AXUIElement`) to capture content and context (active window, selected text).
- **Data Layer (SwiftData)**: The `Item` model stores clipboard history, including timestamp, content type (text/image), app source, and vector embeddings.
- **AI Services**:
  - `GeminiService`: Interfaces with Google's Gemini API for semantic tagging and question answering (Gemini 2.5 Flash).
  - `LocalAIService`: Interfaces with a local LLM (e.g., Qwen via local endpoint) for privacy-focused operations.
  - `ElevenLabsService`: Handles voice-to-text transcription for voice input.

- **SuggestionEngine**: Ranks clipboard items based on vector similarity (embeddings), recency, and frequency.
- **UI Layer (SwiftUI)**: `ContentView` is the main interface. `FloatingDogWindowController` manages the "Clippy-like" floating assistant.

### Data Flow
1. **Capture**: `ClipboardMonitor` detects changes -> Captures content -> Captures Context (AX).
2. **Process**: Content is passed to `GeminiService` or `LocalAIService` for tagging.
3. **Store**: `Item` is saved to `SwiftData`. Embeddings are generated and stored via `Clippy`.
4. **Retrieval**: User query -> `SuggestionEngine` searches embeddings -> Returns ranked `Item` list.

## 3. Build Configuration
- **Project File**: `Clippy.xcodeproj`
- **Targets**: `Clippy` (macOS App)
- **Bundle Identifier**: `altic.Clippy`
- **Dependencies**:
  - `VecturaKit`: Vector database/search.
  - `VecturaMLXKit`: Machine learning extensions.
- **Build Configuration**:
  - Minimum Deployment Target: macOS 15.0
  - Swift Version: 5.0

## 4. Keyboard Shortcuts
- **Option+X**: Text capture mode - type a question, press again to submit
- **Option+Space**: Voice capture mode - speak a question, press again to submit
- **Option+V**: Vision/OCR mode - captures and parses on-screen text
- **Option+S**: Legacy suggestions mode

## 5. Key Files
| File | Purpose |
|------|---------|
| `ContentView.swift` | Main UI and hotkey orchestration |
| `ClipboardMonitor.swift` | Clipboard change detection |
| `GeminiService.swift` | Google Gemini AI integration |
| `LocalAIService.swift` | Local LLM integration |
| `ElevenLabsService.swift` | Voice transcription |
| `TextCaptureService.swift` | Text input capture and injection |
| `VisionScreenParser.swift` | Screen OCR using Vision framework |
| `FloatingDogWindowController.swift` | Animated assistant overlay |
| `SuggestionEngine.swift` | Clipboard item ranking |
| `Clippy.swift` | Vector embeddings (currently disabled) |
