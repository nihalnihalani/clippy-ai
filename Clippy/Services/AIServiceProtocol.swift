import Foundation

/// Unified protocol for AI services (Gemini, Local AI, etc.)
/// Allows the View layer to be agnostic of the underlying AI implementation.
@MainActor
protocol AIServiceProtocol: AnyObject, ObservableObject {
    var isProcessing: Bool { get }
    
    /// Generate an answer based on user question and clipboard context
    func generateAnswer(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) async -> String?
    
    /// Generate semantic tags for clipboard content
    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String]
    
    /// Analyze an image and return a description
    func analyzeImage(imageData: Data) async -> String?
}

/// Shared type for RAG context items used by both AI services
struct RAGContextItem: Sendable {
    let content: String
    let tags: [String]
    let type: String
    let timestamp: Date
    let title: String?
    
    init(content: String, tags: [String], type: String = "text", timestamp: Date = Date(), title: String? = nil) {
        self.content = content
        self.tags = tags
        self.type = type
        self.timestamp = timestamp
        self.title = title
    }
}
