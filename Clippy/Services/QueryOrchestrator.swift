import Foundation
import SwiftData
import os

/// Orchestrates the RAG query pipeline: vector search, context building, and AI dispatch.
/// Extracted from ContentView.processCapturedText to keep view logic minimal.
@MainActor
class QueryOrchestrator: ObservableObject {
    // Dependencies
    private let vectorSearch: VectorSearchService
    private let geminiService: GeminiService
    private let localAIService: LocalAIService
    var aiRouter: AIRouter?

    @Published var isProcessing = false

    struct QueryResult {
        let answer: String?
        let imageIndex: Int?
        let contextItems: [Item]
        let errorMessage: String?
    }

    init(vectorSearch: VectorSearchService, geminiService: GeminiService, localAIService: LocalAIService) {
        self.vectorSearch = vectorSearch
        self.geminiService = geminiService
        self.localAIService = localAIService
    }

    /// Run the full RAG pipeline: search -> build context -> generate answer.
    ///
    /// - Parameters:
    ///   - query: The user's question text.
    ///   - allItems: All SwiftData `Item` objects to match vector IDs against.
    ///   - aiServiceType: Which AI backend to use (.local or .gemini).
    ///   - appName: The frontmost app name for prompt context.
    ///   - onStreamingToken: Optional callback invoked with the accumulated answer so far
    ///     during local AI streaming, useful for live UI preview.
    /// - Returns: A `QueryResult` containing the answer, optional image index, matched context items, and any error.
    func processQuery(
        query: String,
        allItems: [Item],
        aiServiceType: AIServiceType,
        appName: String?,
        onStreamingToken: ((String) -> Void)? = nil
    ) async -> QueryResult {
        isProcessing = true
        defer { isProcessing = false }

        // 1. Semantic vector search
        let searchResults = await vectorSearch.search(query: query, limit: 30)
        let foundVectorIds = Set(searchResults.map { $0.0 })

        // 2. Match vector IDs to SwiftData items, ordered by search score
        var relevantItems: [Item] = []
        if !foundVectorIds.isEmpty {
            let itemsByVectorId = allItems.filter { item in
                guard let vid = item.vectorId else { return false }
                return foundVectorIds.contains(vid)
            }
            relevantItems = searchResults.compactMap { (id, _) in
                itemsByVectorId.first(where: { $0.vectorId == id })
            }
        }

        // 3. Supplement with recent items when search yields few results
        if relevantItems.count < 5 {
            let recentItems = Array(allItems.prefix(5))
            for item in recentItems {
                if !relevantItems.contains(where: { $0.timestamp == item.timestamp }) {
                    relevantItems.append(item)
                }
            }
        }

        // 4. Build RAG context (skip sensitive items)
        let safeItems = relevantItems.filter { !$0.isSensitive }
        let clipboardContext: [RAGContextItem] = safeItems.map { item in
            RAGContextItem(
                content: item.content,
                tags: item.tags,
                type: item.contentType,
                timestamp: item.timestamp,
                title: item.title
            )
        }
        Logger.ai.info("RAG Context: \(relevantItems.count, privacy: .public) items (\(searchResults.count, privacy: .public) from search)")

        // 5. Dispatch to selected AI service
        let answer: String?
        let imageIndex: Int?

        switch aiServiceType {
        case .gemini:
            let simpleContext = safeItems.map { ($0.content, $0.tags) }
            (answer, imageIndex) = await geminiService.generateAnswerWithImageDetection(
                question: query,
                clipboardContext: simpleContext,
                appName: appName
            )

        case .local:
            var fullAnswer = ""
            do {
                let stream = localAIService.generateAnswerStream(
                    question: query,
                    clipboardContext: clipboardContext,
                    appName: appName
                )
                for try await token in stream {
                    fullAnswer += token
                    onStreamingToken?(fullAnswer)
                }
                answer = fullAnswer
            } catch {
                Logger.ai.error("Streaming error: \(error.localizedDescription, privacy: .public)")
                answer = nil
            }
            imageIndex = nil

        case .claude, .openai, .ollama:
            // Route through the AIRouter for new providers
            answer = await aiRouter?.generateAnswer(
                question: query,
                clipboardContext: clipboardContext,
                appName: appName
            )
            imageIndex = nil
        }

        let errorMessage: String?
        switch aiServiceType {
        case .gemini:
            errorMessage = geminiService.lastErrorMessage
        case .local, .claude, .openai, .ollama:
            errorMessage = nil
        }
        return QueryResult(
            answer: answer,
            imageIndex: imageIndex,
            contextItems: relevantItems,
            errorMessage: errorMessage
        )
    }
}
