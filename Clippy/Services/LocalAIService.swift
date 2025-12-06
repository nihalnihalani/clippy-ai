import Foundation

// Local AI API Response Structure
struct LocalAIResponse: Codable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [Choice]?
    let usage: Usage?
    
    struct Choice: Codable {
        let index: Int?
        let message: Message?
        let delta: Delta?
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case index, message, delta
            case finishReason = "finish_reason"
        }
    }
    
    struct Message: Codable {
        let role: String?
        let content: String?
    }
    
    struct Delta: Codable {
        let role: String?
        let content: String?
    }
    
    struct Usage: Codable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

@MainActor
class LocalAIService: ObservableObject, AIServiceProtocol {
    @Published var isProcessing = false
    @Published var lastError: String?
    
    // Endpoints configuration
    private let visionEndpoint = "http://localhost:8081/chat/completions"
    private let ragEndpoint = "http://localhost:8082/v1/chat/completions"
    private let extractEndpoint = "http://localhost:8083/v1/chat/completions"
    
    // Models configuration
    private let visionModel = "mlx-community/LFM2-VL-3B-4bit"
    private let ragModel = "LiquidAI/LFM2-1.2B-RAG"
    private let extractModel = "LiquidAI/LFM2-1.2B-Extract"

    init() {}

    // MARK: - Vision (LFM2-VL-3B)

    /// Generate a description for an image using LFM2-VL-3B
    func generateVisionDescription(base64Image: String, screenText: String? = nil) async -> String? {
        print("👁️ [LocalAIService] Generating vision description...")
        isProcessing = true
        defer { isProcessing = false }
        
        var prompt = """
        Analyze this screen content in high detail for future reference.
        """
        
        if let text = screenText, !text.isEmpty {
            prompt += "\n\nCONTEXT FROM SCREEN TEXT (Use this to verify details/code/filenames):\n\(text.prefix(2000))\n"
        }
        
        prompt += """
        
        STRICT OUTPUT FORMAT:
        Title: [Action/Topic] - [Key Subject]
        Files/Context:
        1. [File 1]
        2. [File 2]
        (List MAX 5 distinct files. STOP after 5.)

        Code:
        - [Description of visible code]
        - [Key variables/functions]

        Terminal:
        - [Last command]
        - [Output summary]

        Intent:
        - [User's likely goal]

        CONSTRAINTS:
        - OUTPUT MUST START DIRECTLY WITH "Title:".
        - DO NOT WRITE ANY PREAMBLE OR CONVERSATIONAL TEXT (e.g., "Here is the analysis...").
        - Files/Context: Max 5 items. ABSOLUTELY NO REPETITION.
        - Code/Terminal/Intent: Use bullet points.
        - STOP generating if you start repeating.
        """
        
        // Custom format for our vision server
        let requestBody: [String: Any] = [
            "model": visionModel,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]]
                    ]
                ]
            ],
            "max_tokens": 1024,
            "temperature": 0.7
        ]
        
        return await makeRequest(endpoint: visionEndpoint, body: requestBody, extractField: "content")
    }
    
    /// Protocol conformance: Analyze image data and return description
    func analyzeImage(imageData: Data) async -> String? {
        let base64Image = imageData.base64EncodedString()
        return await generateVisionDescription(base64Image: base64Image)
    }
    
    // MARK: - RAG (LFM2-1.2B-RAG)
    
    /// Generate an answer based on user question and clipboard context using LFM2-1.2B-RAG
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
        <context>
        \(contextText)
        </context>
        
        Question: \(question)
        
        Instructions:
        1. Answer the Question accurately based on the <context>.
        2. If the answer is NOT in the <context>, reply with "I couldn't find that information in your clipboard history."
        
        Answer:
        """
        
        let requestBody: [String: Any] = [
            "model": ragModel,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 256,
            "temperature": 0.3
        ]
        
        return await makeRequest(endpoint: ragEndpoint, body: requestBody, extractField: "content")
    }

    /// Generate a streaming answer
    func generateAnswerStream(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) -> AsyncThrowingStream<String, Error> {
        print("🤖 [LocalAIService] Generating Streaming RAG answer...")
        // Note: isProcessing isn't easily toggleable here since it returns immediately.
        // The consumer should handle loading state.
        
        let contextText = buildContextString(clipboardContext) // Uses default safe limit (10k)
        let prompt = """
        <context>
        \(contextText)
        </context>
        
        Question: \(question)
        
        Instructions:
        1. Answer the Question using ONLY the information provided in the <context>.
        2. If the answer is in the <context>, provide it exactly.
        3. If the answer is NOT in the <context>, reply with "I couldn't find that information in your clipboard history."
        
        Answer:
        """
        
        print("📝 [LocalAIService] RAG Prompt Preview:\n\(prompt.prefix(200))...")
        
        let requestBody: [String: Any] = [
            "model": ragModel,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 512,
            "temperature": 0.3
        ]
        
        // We need to call actor synchronously to get the stream object, 
        // but actor calls are async.
        // AsyncThrowingStream init can wrap the async call.
        
        return AsyncThrowingStream { continuation in
            Task {
                let stream = await AIActor.shared.makeRequestStream(endpoint: ragEndpoint, body: requestBody, apiKey: nil)
                for try await token in stream {
                    continuation.yield(token)
                }
                continuation.finish()
            }
        }
    }
    
    // MARK: - Extract (LFM2-1.2B-Extract)
    
    /// Extract structured data from text using LFM2-1.2B-Extract
    func extractStructuredData(text: String, schema: String) async -> String? {
        print("⛏️ [LocalAIService] Extracting data...")
        isProcessing = true
        defer { isProcessing = false }
        
        let prompt = "Extract the following information from the text. Return ONLY the requested data in the specified format. No conversational text.\nText: \"\(text)\"\nSchema: \(schema)"
        
        let requestBody: [String: Any] = [
            "model": extractModel,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 512,
            "temperature": 0.1
        ]
        
        return await makeRequest(endpoint: extractEndpoint, body: requestBody, extractField: "content")
    }
    
    // MARK: - Transform (LFM2-1.2B-RAG)
    
    /// Transform text based on an instruction
    func transformText(text: String, instruction: String) async -> String? {
        print("🪄 [LocalAIService] Transforming text...")
        isProcessing = true
        defer { isProcessing = false }
        
        // Truncate input if necessary
        let safeText = String(text.prefix(3000))
        
        let prompt = """
        Instruction: \(instruction)
        
        Input Text:
        \(safeText)
        
        Output:
        """
        
        let requestBody: [String: Any] = [
            "model": ragModel, // Reuse RAG model for general instructions
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 1024,
            "temperature": 0.2
        ]
        
        return await makeRequest(endpoint: ragEndpoint, body: requestBody, extractField: "content")
    }
    
    // MARK: - Helper Methods
    
    private func buildContextString(_ clipboardContext: [RAGContextItem], maxLength: Int = 10000) -> String {
        if clipboardContext.isEmpty { return "No context available." }
        
        let now = Date()
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        
        var currentLength = 0
        var builtString = ""
        
        for (index, item) in clipboardContext.enumerated() {
            let timeString = formatter.localizedString(for: item.timestamp, relativeTo: now)
            var metaParts: [String] = []
            
            // Type & Time
            metaParts.append("[Type: \(item.type)]")
            metaParts.append("[Time: \(timeString)]")
            
            // Title
            if let title = item.title, !title.isEmpty {
                metaParts.append("[Title: \(title)]")
            }
            
            // Tags
            if !item.tags.isEmpty {
                metaParts.append("[Tags: \(item.tags.joined(separator: ", "))]")
            }
            
            let metaLine = metaParts.joined(separator: " ")
            let itemString = "[\(index + 1)] \(metaLine)\n\(item.content)"
            
            // Check length limit
            if currentLength + itemString.count > maxLength {
                builtString += "\n\n... (Context truncated)"
                break
            }
            
            if !builtString.isEmpty {
                builtString += "\n\n---\n\n"
            }
            builtString += itemString
            currentLength += builtString.count
        }
        
        return builtString
    }
    
    private func makeRequest(endpoint: String, body: [String: Any], extractField: String) async -> String? {
        do {
            // Offload networking and parsing to background actor
            let result = try await AIActor.shared.makeRequest(endpoint: endpoint, body: body, apiKey: nil)
            return result
        } catch {
            print("❌ [LocalAIService] Request failed: \(error.localizedDescription)")
            // Update UI state on Main Actor
            self.lastError = error.localizedDescription
            return nil
        }
    }
    
    /// Compatibility method for existing code (Tagging) - uses RAG model for now
    func generateTags(content: String, appName: String?, context: String?) async -> [String] {
        // Simple implementation using RAG model for tagging
        let prompt = """
        Analyze this text and generate 3-5 concise keywords/tags.
        Rules:
        1. Return ONLY a comma-separated list (e.g. "Tag1, Tag2, Tag3").
        2. Do NOT use numbered lists.
        3. Do NOT write full sentences or introductions like "Here are the tags".
        
        Text: "\(content.prefix(500))"
        """
        
        guard let response = await generateAnswer(question: prompt, clipboardContext: [], appName: appName) else {
            return []
        }
        
        // Robust cleaning and parsing
        var cleanResponse = response
        
        // Remove common conversational prefixes
        let prefixesToRemove = ["Here are", "The tags are", "Keywords:", "Tags:"]
        for prefix in prefixesToRemove {
            if let range = cleanResponse.range(of: prefix, options: .caseInsensitive) {
                cleanResponse.removeSubrange(cleanResponse.startIndex..<range.upperBound)
            }
        }
        
        // Split by newlines or commas
        let separators = CharacterSet(charactersIn: ",\n")
        let rawTags = cleanResponse.components(separatedBy: separators)
        
        let tags = rawTags.compactMap { rawTag -> String? in
            // Clean up each tag (remove "1.", "- ", etc.)
            let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = trimmed
                .replacingOccurrences(of: "^[0-9]+\\.", with: "", options: .regularExpression) // Remove "1."
                .replacingOccurrences(of: "^- ", with: "", options: .regularExpression)        // Remove "- "
                .replacingOccurrences(of: "^• ", with: "", options: .regularExpression)        // Remove "• "
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            return cleaned.isEmpty ? nil : cleaned
        }
        
        return Array(Set(tags)).prefix(5).sorted() // Dedupe and limit
    }
}
