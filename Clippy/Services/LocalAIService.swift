import Foundation
import MLXLLM
import MLXLMCommon
import MLX

/// Native Local AI Service using MLX-Swift for in-process LLM inference.
/// No external Python servers required - runs entirely on Apple Silicon.
@MainActor
class LocalAIService: ObservableObject, AIServiceProtocol {
    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var isModelLoaded = false
    @Published var loadingProgress: Double = 0.0
    @Published var statusMessage: String = "Not loaded"
    
    // Model container for LLM
    private var modelContainer: ModelContainer?
    
    // Model configuration - using smaller model for Mac
    private let modelId = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    
    init() {}
    
    // MARK: - Model Loading
    
    /// Load the LLM model into memory
    func loadModel() async {
        guard modelContainer == nil else {
            print("✅ [LocalAIService] Model already loaded")
            return
        }
        
        print("🔄 [LocalAIService] Loading model: \(modelId)")
        statusMessage = "Downloading model..."
        isProcessing = true
        
        do {
            // Use LLMModelFactory to load the model
            modelContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: LLMRegistry.qwen2_5_1_5b
            ) { progress in
                Task { @MainActor in
                    self.loadingProgress = progress.fractionCompleted
                    if progress.fractionCompleted < 1.0 {
                        self.statusMessage = "Loading: \(Int(progress.fractionCompleted * 100))%"
                    }
                }
            }
            
            isModelLoaded = true
            statusMessage = "Ready (Qwen2.5-1.5B)"
            print("✅ [LocalAIService] Model loaded successfully")
            
        } catch {
            print("❌ [LocalAIService] Failed to load model: \(error)")
            lastError = error.localizedDescription
            statusMessage = "Failed: \(error.localizedDescription)"
        }
        
        isProcessing = false
    }
    
    // MARK: - Text Generation
    
    /// Generate text completion from a prompt
    private func generate(prompt: String, maxTokens: Int = 512) async -> String? {
        guard let container = modelContainer else {
            print("⚠️ [LocalAIService] Model not loaded, loading now...")
            await loadModel()
            guard let container = modelContainer else { return nil }
            return await generateWithContainer(container, prompt: prompt, maxTokens: maxTokens)
        }
        
        return await generateWithContainer(container, prompt: prompt, maxTokens: maxTokens)
    }
    
    private func generateWithContainer(_ container: ModelContainer, prompt: String, maxTokens: Int) async -> String? {
        do {
            let result = try await container.perform { context in
                let input = try await context.processor.prepare(input: .init(prompt: prompt))
                return try MLXLMCommon.generate(
                    input: input,
                    parameters: .init(temperature: 0.3, topP: 0.9),
                    context: context
                ) { tokens in
                    if tokens.count >= maxTokens {
                        return .stop
                    }
                    return .more
                }
            }
            
            return result.output
            
        } catch {
            print("❌ [LocalAIService] Generation error: \(error)")
            lastError = error.localizedDescription
            return nil
        }
    }
    
    // MARK: - AIServiceProtocol Implementation
    
    /// Generate an answer based on user question and clipboard context
    func generateAnswer(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) async -> String? {
        print("🤖 [LocalAIService] Generating RAG answer...")
        isProcessing = true
        defer { isProcessing = false }
        
        let contextText = buildContextString(clipboardContext)
        let prompt = """
        <|im_start|>system
        You are a helpful assistant that answers questions based on the user's clipboard history.
        <|im_end|>
        <|im_start|>user
        Context from clipboard history:
        \(contextText)
        
        Question: \(question)
        
        Instructions:
        1. Answer the question using ONLY information from the context above.
        2. If the answer is not in the context, say "I couldn't find that in your clipboard history."
        3. Be concise and direct.
        <|im_end|>
        <|im_start|>assistant
        """
        
        return await generate(prompt: prompt, maxTokens: 256)
    }

    /// Generate a streaming answer
    func generateAnswerStream(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) -> AsyncThrowingStream<String, Error> {
        print("🤖 [LocalAIService] Generating Streaming answer...")
        
        let contextText = buildContextString(clipboardContext)
        let prompt = """
        <|im_start|>system
        You are a helpful assistant that answers questions based on the user's clipboard history.
        <|im_end|>
        <|im_start|>user
        Context from clipboard history:
        \(contextText)
        
        Question: \(question)
        
        Instructions:
        1. Answer the question using ONLY information from the context above.
        2. If the answer is not in the context, say "I couldn't find that in your clipboard history."
        3. Be concise and direct.
        <|im_end|>
        <|im_start|>assistant
        """
        
        return AsyncThrowingStream { continuation in
            Task {
                if let response = await self.generate(prompt: prompt, maxTokens: 512) {
                    let words = response.components(separatedBy: " ")
                    for word in words {
                        continuation.yield(word + " ")
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                continuation.finish()
            }
        }
    }
    
    /// Generate tags for content
    func generateTags(content: String, appName: String?, context: String?) async -> [String] {
        let prompt = """
        <|im_start|>system
        You are a tagging assistant. Generate 3-5 relevant tags for the given content.
        <|im_end|>
        <|im_start|>user
        Generate tags for this text. Return ONLY a comma-separated list of tags, nothing else.
        
        Text: "\(content.prefix(500))"
        <|im_end|>
        <|im_start|>assistant
        """
        
        guard let response = await generate(prompt: prompt, maxTokens: 50) else {
            return []
        }
        
        let tags = response
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count < 30 }
            .prefix(5)
        
        return Array(tags)
    }
    
    /// Analyze image - placeholder (would need MLXVLM)
    func analyzeImage(imageData: Data) async -> String? {
        print("⚠️ [LocalAIService] Vision not implemented in pure Swift mode")
        return "Image analysis requires vision model"
    }
    
    /// Vision description - placeholder
    func generateVisionDescription(base64Image: String, screenText: String? = nil) async -> String? {
        return screenText ?? "Image analysis requires vision model"
    }
    
    /// Transform text based on an instruction (for context menu actions)
    func transformText(text: String, instruction: String) async -> String? {
        let prompt = """
        <|im_start|>system
        You are a text transformation assistant. Apply the user's instruction to transform the text.
        <|im_end|>
        <|im_start|>user
        Instruction: \(instruction)
        
        Text to transform:
        \(text.prefix(2000))
        
        Output ONLY the transformed text, nothing else.
        <|im_end|>
        <|im_start|>assistant
        """
        
        return await generate(prompt: prompt, maxTokens: 512)
    }
    
    // MARK: - Helper Methods
    
    private func buildContextString(_ clipboardContext: [RAGContextItem], maxLength: Int = 5000) -> String {
        if clipboardContext.isEmpty { return "No context available." }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let now = Date()
        
        var result = ""
        
        for (index, item) in clipboardContext.prefix(10).enumerated() {
            let timeString = formatter.localizedString(for: item.timestamp, relativeTo: now)
            var entry = "[\(index + 1)] (\(timeString)) "
            
            if let title = item.title, !title.isEmpty {
                entry += "[\(title)] "
            }
            
            entry += String(item.content.prefix(500))
            result += entry + "\n\n"
            
            if result.count > maxLength { break }
        }
        
        return result
    }
}
