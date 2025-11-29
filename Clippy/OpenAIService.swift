import Foundation

// Responses API Response (for GPT-4.1 and GPT-5 models)
// Uses: gpt-4.1-nano for tagging, gpt-5-nano for answering
struct OpenAIResponsesAPIResponse: Codable {
    let id: String?
    let output: [OutputMessage]?
    let usage: Usage?
    
    struct OutputMessage: Codable {
        let id: String?
        let type: String
        let status: String?
        let content: [ContentItem]?  // Optional because reasoning type doesn't have content
        let role: String?
        
        // Extract the actual text from the first content item
        var actualContent: String? {
            return content?.first?.text
        }
    }
    
    struct ContentItem: Codable {
        let type: String
        let text: String
        let annotations: [String]?
        let logprobs: [String]?
        
        enum CodingKeys: String, CodingKey {
            case type
            case text
            case annotations
            case logprobs
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            text = try container.decode(String.self, forKey: .text)
            annotations = try container.decodeIfPresent([String].self, forKey: .annotations)
            logprobs = try container.decodeIfPresent([String].self, forKey: .logprobs)
        }
    }
    
    struct Usage: Codable {
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

@MainActor
class OpenAIService: ObservableObject {
    @Published var isProcessing = false
    @Published var lastError: String?
    
    private let apiKey: String
    private let responsesURL = "https://api.openai.com/v1/responses"
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Generate an answer based on user question and clipboard context
    /// Returns tuple: (textAnswer, imageIndexToPaste)
    func generateAnswerWithImageDetection(
        question: String,
        clipboardContext: [(content: String, tags: [String])],
        appName: String?
    ) async -> (answer: String?, imageIndex: Int?) {
        print("🤖 [OpenAIService] Generating answer with image detection...")
        print("   Question: \(question)")
        print("   Clipboard items: \(clipboardContext.count)")
        
        isProcessing = true
        defer { isProcessing = false }
        
        // Build the prompt
        let prompt = buildAnswerPrompt(question: question, clipboardContext: clipboardContext, appName: appName)
        
        // Make API call
        guard let (answer, imageIndex) = await callOpenAIForAnswerWithImage(prompt: prompt) else {
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
    
    /// Generate semantic tags for clipboard content to improve retrieval
    /// Returns tags like: ["terminal", "python", "code", "error_message"]
    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        print("🏷️  [OpenAIService] Generating tags...")
        print("   Content: \(content.prefix(100))...")
        print("   App: \(appName ?? "Unknown")")
        
        isProcessing = true
        defer { isProcessing = false }
        
        // Build the prompt
        let prompt = buildTaggingPrompt(content: content, appName: appName, context: context)
        
        // Make API call
        guard let tags = await callOpenAI(prompt: prompt) else {
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
    
    private func callOpenAIForAnswerWithImage(prompt: String) async -> (String?, Int?)? {
        guard !apiKey.isEmpty, apiKey != "your-api-key-here" else {
            print("   ⚠️  No valid API key configured")
            return nil
        }
        
        print("   📤 Sending prompt to OpenAI for answer using Responses API:")
        
        // New Responses API format for gpt-5-nano (answering)
        let requestBody: [String: Any] = [
            "model": "gpt-5",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": prompt
                ]
            ],
            "text": [
                "format": [
                    "type": "json_object"
                ]
            ],
            "reasoning": [
                "effort": "low",
                "summary": NSNull()
            ] as [String: Any],
            "tools": [],
            "max_output_tokens": 2048
        ]
        
        guard let url = URL(string: responsesURL) else {
            lastError = "Invalid URL"
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return nil
            }
            
            print("   📡 OpenAI Response Status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                lastError = "API Error (\(httpResponse.statusCode)): \(errorMessage)"
                print("   ❌ API Error: \(errorMessage)")
                return nil
            }
            
            // Parse response using new Responses API structure
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(OpenAIResponsesAPIResponse.self, from: data)
            
            // Extract JSON content from response
            guard let output = apiResponse.output else {
                lastError = "No output in response"
                return nil
            }
            
            let messageOutput = output.first { $0.type == "message" }
            guard let jsonText = messageOutput?.actualContent else {
                lastError = "No message content in response"
                return nil
            }
            
            print("   📝 Extracted JSON: \(jsonText)")
            
            // Parse the JSON to extract both answer and paste_image
            if let jsonData = jsonText.data(using: .utf8),
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
            return (jsonText.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            
        } catch {
            lastError = error.localizedDescription
            print("   ❌ Error: \(error)")
            return nil
        }
    }
    
    private func callOpenAI(prompt: String) async -> [String]? {
        guard !apiKey.isEmpty, apiKey != "your-api-key-here" else {
            print("   ⚠️  No valid API key configured")
            return nil
        }
        
        print("   📤 Sending prompt to OpenAI for tagging using Responses API:")
        print("   \(prompt)")
        
        // New Responses API format for gpt-4.1-nano (tagging)
        let requestBody: [String: Any] = [
            "model": "gpt-4.1-nano",
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": prompt
                ]
            ],
            "text": [
                "format": [
                    "type": "json_object"
                ]
            ],
            "reasoning": [:],
            "tools": [],
            "temperature": 0.3,
            "max_output_tokens": 2048,
            "top_p": 1
        ]
        
        guard let url = URL(string: responsesURL) else {
            lastError = "Invalid URL"
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            // Print request body for debugging
            if let requestJSON = try? JSONSerialization.data(withJSONObject: requestBody),
               let requestString = String(data: requestJSON, encoding: .utf8) {
                print("   📤 Request Body: \(requestString)")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return nil
            }
            
            print("   📡 OpenAI Response Status: \(httpResponse.statusCode)")
            
            // Print raw response for debugging
            if let rawResponse = String(data: data, encoding: .utf8) {
                print("   📄 Raw Response: \(rawResponse)")
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                lastError = "API Error (\(httpResponse.statusCode)): \(errorMessage)"
                print("   ❌ API Error: \(errorMessage)")
                return nil
            }
            
            // Parse response using new Responses API structure
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(OpenAIResponsesAPIResponse.self, from: data)
            
            // Extract tags from response - find the message type output
            guard let output = apiResponse.output else {
                lastError = "No output in response"
                print("   ❌ No output found in response")
                return nil
            }
            
            // Find the first message type output (skip reasoning type)
            let messageOutput = output.first { $0.type == "message" }
            guard let tagsText = messageOutput?.actualContent else {
                lastError = "No message content in response"
                print("   ❌ No message content found in response")
                return nil
            }
            
            print("   📝 Extracted text: \(tagsText)")
            
            // Try parsing as JSON first
            if let jsonData = tagsText.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let tagsArray = jsonObject["tags"] as? [String] {
                let tags = tagsArray.map { $0.lowercased() }.filter { !$0.isEmpty }
                print("   ✅ Parsed JSON tags: \(tags)")
                return tags
            }
            
            // Fallback to comma-separated parsing
            print("   ⚠️ JSON parsing failed, trying comma-separated format")
            let tags = tagsText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            
            return tags
            
        } catch {
            lastError = error.localizedDescription
            print("   ❌ Error: \(error)")
            return nil
        }
    }
    
    /// Analyze image and return a summary description
    func analyzeImage(imageData: Data) async -> String? {
        guard !apiKey.isEmpty, apiKey != "your-api-key-here" else {
            print("   ⚠️  No valid API key configured")
            return nil
        }
        
        print("🖼️ [OpenAIService] Analyzing image...")
        print("   Image size: \(imageData.count) bytes")
        
        let base64Image = imageData.base64EncodedString()
        
        let requestBody: [String: Any] = [
            "model": "gpt-4.1-mini",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "give quick summary of it."
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64,\(base64Image)"
                            ]
                        ]
                    ]
                ]
            ],
            "max_tokens": 500
        ]
        
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            
            print("   📡 OpenAI Vision Response Status: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("   ❌ API Error: \(errorMessage)")
                return nil
            }
            
            // Parse response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let message = firstChoice["message"] as? [String: Any],
               let content = message["content"] as? String {
                print("   ✅ Image analysis: \(content.prefix(100))...")
                return content
            }
            
            return nil
        } catch {
            print("   ❌ Error: \(error)")
            return nil
        }
    }
    
    /// Convenience method to get API key from environment
    static func fromEnvironment() -> OpenAIService? {
        if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] {
            return OpenAIService(apiKey: apiKey)
        }
        return nil
    }
}
