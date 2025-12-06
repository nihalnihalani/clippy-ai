import Foundation
import SwiftData
import VecturaMLXKit
import VecturaKit
import MLXEmbedders

@MainActor
class Clippy: ObservableObject {
    @Published var isInitialized = false
    @Published var statusMessage = "Initializing embedding service..."
    
    private var vectorDB: VecturaMLXKit?
    
    func initialize() async {
        print("🚀 [Clippy] Initializing...")
        do {
            let config = VecturaConfig(
                name: "pastepup-clipboard-v2",
                dimension: nil as Int? // Auto-detect from model
            )
            
            vectorDB = try await VecturaMLXKit(
                config: config,
                modelConfiguration: .qwen3_embedding
            )
             
            isInitialized = true
            statusMessage = "Ready (Qwen3-Embedding-0.6B)"
            print("✅ [Clippy] Initialized successfully with Qwen3")
        } catch {
            statusMessage = "Failed to initialize: \(error.localizedDescription)"
            print("❌ [Clippy] Initialization error: \(error)")
        }
    }
    
    func addDocument(vectorId: UUID, text: String) async {
        await addDocuments(items: [(vectorId, text)])
    }
    
    func addDocuments(items: [(UUID, String)]) async {
        guard let vectorDB = vectorDB else { 
            print("⚠️ [Clippy] Cannot add documents - vectorDB not initialized")
            return 
        }
        
        let count = items.count
        print("📝 [Clippy] Adding \(count) documents...")
        
        do {
            let texts = items.map { $0.1 }
            let ids = items.map { $0.0 }
            
            _ = try await vectorDB.addDocuments(
                texts: texts,
                ids: ids
            )
            print("   ✅ Added \(count) documents to Vector DB")
        } catch {
            print("   ❌ Failed to add documents: \(error)")
        }
    }
    
    func search(query: String, limit: Int = 10) async -> [(UUID, Float)] {
        guard let vectorDB = vectorDB else { 
            print("⚠️ [Clippy] Cannot search - vectorDB not initialized")
            return [] 
        }
        
        print("🔎 [Clippy] Searching for: '\(query)' (limit: \(limit))")
        
        do {
            let results = try await vectorDB.search(
                query: query,
                numResults: limit,
                threshold: nil // No threshold, we'll rank ourselves
            )
            
            print("   ✅ Found \(results.count) results")
            for (index, result) in results.prefix(5).enumerated() {
                print("      \(index + 1). ID: \(result.id), Score: \(String(format: "%.3f", result.score))")
            }
            
            return results.map { ($0.id, $0.score) }
        } catch {
            print("   ❌ Search error: \(error)")
            return []
        }
    }
    
    func deleteDocument(vectorId: UUID) async throws {
        guard let vectorDB = vectorDB else { return }
        
        try await vectorDB.deleteDocuments(ids: [vectorId])
    }
}
