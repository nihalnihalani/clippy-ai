import Foundation

// Gemini API Response
struct GeminiAPIResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable {
            struct Part: Codable {
                let text: String?
            }
            let parts: [Part]?
            let role: String?
        }
        let content: Content?
        let finishReason: String?
    }
    let candidates: [Candidate]?
}

@MainActor
class GeminiService: ObservableObject, AIServiceProtocol {
    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var lastErrorMessage: String? // User-friendly error message
    
    private var apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    private let modelName = "gemini-2.5-flash"
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Update the API key
    func updateApiKey(_ key: String) {
        self.apiKey = key
    }
    
    /// Check if API key is configured
    var hasValidAPIKey: Bool {
        !apiKey.isEmpty
    }
    
    /// Clear the last error
    func clearError() {
        lastError = nil
        lastErrorMessage = nil
    }
    
    /// Generate an answer based on user question and clipboard context
    /// Returns tuple: (textAnswer, imageIndexToPaste)
    func generateAnswerWithImageDetection(
        question: String,
        clipboardContext: [(content: String, tags: [String])],
        appName: String?
    ) async -> (answer: String?, imageIndex: Int?) {
        print("🤖 [GeminiService] Generating answer with image detection...")
        print("   Question: \(question)")
        print("   Clipboard items: \(clipboardContext.count)")
        
        isProcessing = true
        defer { isProcessing = false }
        
        // Build the prompt
        let prompt = buildAnswerPrompt(question: question, clipboardContext: clipboardContext, appName: appName)
        
        // Make API call
        guard let (answer, imageIndex) = await callGeminiForAnswerWithImage(prompt: prompt) else {
            print("   ❌ Failed to generate answer")
            return (nil, nil)
        }
        
        if let imageIndex = imageIndex, imageIndex > 0 {
            print("   ✅ Detected image paste request: item \(imageIndex)")
        } else {
            print("   ✅ Generated answer: \(answer?.prefix(100) ?? "empty")...")
        }
        return (answer, imageIndex)
    }
    
    /// Legacy method for backward compatibility
    func generateAnswer(
        question: String,
        clipboardContext: [(content: String, tags: [String])],
        appName: String?
    ) async -> String? {
        let (answer, _) = await generateAnswerWithImageDetection(
            question: question,
            clipboardContext: clipboardContext,
            appName: appName
        )
        return answer
    }
    
    /// Protocol conformance: Generate answer from RAGContextItem array
    func generateAnswer(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) async -> String? {
        // Convert RAGContextItem to legacy tuple format
        let legacyContext = clipboardContext.map { ($0.content, $0.tags) }
        return await generateAnswer(question: question, clipboardContext: legacyContext, appName: appName)
    }
    
    /// Generate semantic tags for clipboard content to improve retrieval
    /// Returns tags like: ["terminal", "python", "code", "error_message"]
    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        print("🏷️  [GeminiService] Generating tags...")
        print("   Content: \(content.prefix(100))...")
        print("   App: \(appName ?? "Unknown")")
        
        isProcessing = true
        defer { isProcessing = false }
        
        // Build the prompt
        let prompt = buildTaggingPrompt(content: content, appName: appName, context: context)
        
        // Make API call
        guard let tags = await callGemini(prompt: prompt) else {
            print("   ❌ Failed to generate tags")
            return []
        }
        
        print("   ✅ Generated tags: \(tags)")
        return tags
    }
    
    private func buildAnswerPrompt(question: String, clipboardContext: [(content: String, tags: [String])], appName: String?) -> String {
        let contextText: String
        if clipboardContext.isEmpty {
            contextText = "No clipboard context available."
        } else {
            contextText = clipboardContext.enumerated().map { index, item in
                let tagsText = item.tags.isEmpty ? "" : " [Tags: \(item.tags.joined(separator: ", "))]"
                return "[\(index + 1)]\(tagsText)\n\(item.content)"
            }.joined(separator: "\n\n---\n\n")
        }
        
        let prompt = """
        You are a Clippy assistant. Answer the user's question based on their clipboard history.
        
        User Question: \(question)
        
        Clipboard Context (with semantic tags):
        \(contextText)
        
        App: \(appName ?? "Unknown")
        
        CRITICAL RULES:
        1. If user asks to paste/show/insert an image (e.g., "paste image 3", "show the screenshot"), return the item number in the paste_image field
        2. For text questions, answer directly in the A field
        3. Do NOT add commentary about API calls, processing, or system operations
        4. If question is not about clipboard content, return empty string
        5. Keep answer concise and directly relevant
        6. **RETURN ONLY THE DIRECT ANSWER** - No conversational wrapper like "Your X is" or "The X is"
        
        ANSWER FORMAT EXAMPLES:
        - "what is my email?" → Return: "yahya.s.alhinai@gmail.com" (NOT "Your email is...")
        - "what is my name?" → Return: "John Smith" (NOT "Your name is...")
        - "what is the tracking number?" → Return: "1ZAC65432428054431" (NOT "The tracking number is...")
        - "what was that code?" → Return the actual code snippet (NOT "Here is the code...")
        
        OUTPUT FORMAT - Return ONLY this JSON structure:
        {
          "A": "direct answer only - no preamble",
          "paste_image": 0
        }
        
        Set paste_image to the item number (1-based) if user wants to paste an image, otherwise 0.
        Examples:
        - "paste image 3" → {"A": "", "paste_image": 3}
        - "show the screenshot" → {"A": "", "paste_image": 1}
        - "what was that code?" → {"A": "the code snippet...", "paste_image": 0}
        """
        
        return prompt
    }
    
    private func buildTaggingPrompt(content: String, appName: String?, context: String?) -> String {
        // Get time of day
        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
        
        let prompt = """
        App: \(appName ?? "Unknown")
        Time: \(timeOfDay)
        Content: \(content.prefix(500))
        
        Generate 3-7 semantic tags for this clipboard item. Focus on content type, domain, and key topics.
        
        Return output in the form of JSON:
        {
          "tags": ["tag1", "tag2", "tag3"]
        }
        
        Return ONLY the JSON, nothing else.
        """
        
        return prompt
    }
    
    private func callGeminiForAnswerWithImage(prompt: String) async -> (String?, Int?)? {
        guard !apiKey.isEmpty else {
            print("   ⚠️  No valid API key configured")
            lastErrorMessage = "API key not configured. Go to Settings to add your Gemini API key."
            return nil
        }
        
        print("   📤 Sending prompt to Gemini for answer...")
        
        // Construct request URL
        guard let url = URL(string: "\(baseURL)/\(modelName):generateContent?key=\(apiKey)") else {
            lastError = "Invalid URL"
            lastErrorMessage = "Configuration error"
            return nil
        }
        
        // Gemini API Request Body
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "response_mime_type": "application/json",
                "maxOutputTokens": 8192
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                lastErrorMessage = "Network error - invalid response"
                return nil
            }
            
            print("   📡 Gemini Response Status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                lastError = "API Error (\(httpResponse.statusCode)): \(errorMessage)"
                
                // Set user-friendly error message
                switch httpResponse.statusCode {
                case 400:
                    lastErrorMessage = "Bad request - check your query"
                case 401, 403:
                    lastErrorMessage = "Invalid API key. Check Settings."
                case 429:
                    lastErrorMessage = "Rate limited. Try again later."
                case 500...599:
                    lastErrorMessage = "Gemini server error. Try again."
                default:
                    lastErrorMessage = "API error (\(httpResponse.statusCode))"
                }
                
                print("   ❌ API Error: \(errorMessage)")
                return nil
            }
            
            // Clear any previous errors on success
            lastErrorMessage = nil
            
            // Parse response
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(GeminiAPIResponse.self, from: data)
            
            guard let text = apiResponse.candidates?.first?.content?.parts?.first?.text else {
                lastError = "No content in response"
                return nil
            }
            
            print("   📝 Extracted JSON: \(text)")
            
            // Clean up markdown code blocks if present
            var cleanText = text
            if cleanText.contains("```json") {
                cleanText = cleanText.replacingOccurrences(of: "```json", with: "")
                cleanText = cleanText.replacingOccurrences(of: "```", with: "")
            } else if cleanText.contains("```") {
                cleanText = cleanText.replacingOccurrences(of: "```", with: "")
            }
            cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            print("   🧹 Cleaned JSON: \(cleanText)")
            
            // Parse the JSON to extract both answer and paste_image
            if let jsonData = cleanText.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let answer = (jsonObject["A"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let pasteImage = jsonObject["paste_image"] as? Int
                
                if let pasteImage = pasteImage, pasteImage > 0 {
                    print("   ✅ Image paste detected: item \(pasteImage)")
                    return (answer, pasteImage)
                } else {
                    print("   ✅ Text answer: \(answer?.prefix(100) ?? "empty")...")
                    return (answer, nil)
                }
            }
            
            // Fallback
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            
        } catch let error as URLError {
            lastError = error.localizedDescription
            // User-friendly network error messages
            switch error.code {
            case .notConnectedToInternet:
                lastErrorMessage = "No internet connection"
            case .timedOut:
                lastErrorMessage = "Request timed out. Try again."
            case .networkConnectionLost:
                lastErrorMessage = "Connection lost. Try again."
            default:
                lastErrorMessage = "Network error. Check connection."
            }
            print("   ❌ Network Error: \(error)")
            return nil
        } catch {
            lastError = error.localizedDescription
            lastErrorMessage = "Something went wrong. Try again."
            print("   ❌ Error: \(error)")
            return nil
        }
    }
    
    private func callGemini(prompt: String) async -> [String]? {
        guard !apiKey.isEmpty else {
            print("   ⚠️  No valid API key configured")
            return nil
        }
        
        print("   📤 Sending prompt to Gemini for tagging...")
        
        guard let url = URL(string: "\(baseURL)/\(modelName):generateContent?key=\(apiKey)") else {
            lastError = "Invalid URL"
            return nil
        }
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "response_mime_type": "application/json",
                "maxOutputTokens": 8192
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return nil
            }
            
            print("   📡 Gemini Response Status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                lastError = "API Error (\(httpResponse.statusCode)): \(errorMessage)"
                print("   ❌ API Error: \(errorMessage)")
                return nil
            }
            
            // Parse response
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(GeminiAPIResponse.self, from: data)
            
            guard let text = apiResponse.candidates?.first?.content?.parts?.first?.text else {
                lastError = "No content in response"
                return nil
            }
            
            print("   📝 Extracted text: \(text)")
            
            // Clean up markdown code blocks if present
            var cleanText = text
            if cleanText.contains("```json") {
                cleanText = cleanText.replacingOccurrences(of: "```json", with: "")
                cleanText = cleanText.replacingOccurrences(of: "```", with: "")
            } else if cleanText.contains("```") {
                cleanText = cleanText.replacingOccurrences(of: "```", with: "")
            }
            cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Try parsing as JSON first
            if let jsonData = cleanText.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let tagsArray = jsonObject["tags"] as? [String] {
                let tags = tagsArray.map { $0.lowercased() }.filter { !$0.isEmpty }
                print("   ✅ Parsed JSON tags: \(tags)")
                return tags
            }
            
            return []
            
        } catch {
            lastError = error.localizedDescription
            print("   ❌ Error: \(error)")
            return nil
        }
    }
    
    /// Analyze image and return a summary description
    func analyzeImage(imageData: Data) async -> String? {
        guard !apiKey.isEmpty else {
            print("   ⚠️  No valid API key configured")
            return nil
        }
        
        print("🖼️ [GeminiService] Analyzing image...")
        print("   Image size: \(imageData.count) bytes")
        
        let base64Image = imageData.base64EncodedString()
        
        guard let url = URL(string: "\(baseURL)/\(modelName):generateContent?key=\(apiKey)") else {
            return nil
        }
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "give quick summary of it."],
                        [
                            "inline_data": [
                                "mime_type": "image/png",
                                "data": base64Image
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 8192
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            
            print("   📡 Gemini Vision Response Status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("   ❌ API Error: \(errorMessage)")
                return nil
            }
            
            // Parse response
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(GeminiAPIResponse.self, from: data)
            
            if let text = apiResponse.candidates?.first?.content?.parts?.first?.text {
                print("   ✅ Image analysis: \(text.prefix(100))...")
                return text
            }
            
            return nil
        } catch {
            print("   ❌ Error: \(error)")
            return nil
        }
    }
    
    /// Convenience method to get API key from environment
    static func fromEnvironment() -> GeminiService? {
        if let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] {
            return GeminiService(apiKey: apiKey)
        }
        return nil
    }
}
