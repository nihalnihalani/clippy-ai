import Foundation
import SwiftData

@MainActor
protocol ClipboardRepository {
    func saveItem(
        content: String,
        appName: String,
        contentType: String,
        timestamp: Date,
        tags: [String],
        vectorId: UUID?,
        imagePath: String?,
        title: String?
    ) async throws -> Item
    
    func deleteItem(_ item: Item) async throws
    
    func updateItem(_ item: Item) async throws
    
    func findDuplicate(content: String) -> Item?
}

@MainActor
class SwiftDataClipboardRepository: ClipboardRepository {
    private let modelContext: ModelContext
    private let vectorService: Clippy // The vector DB service
    
    init(modelContext: ModelContext, vectorService: Clippy) {
        self.modelContext = modelContext
        self.vectorService = vectorService
    }
    
    func saveItem(
        content: String,
        appName: String,
        contentType: String = "text",
        timestamp: Date = Date(),
        tags: [String] = [],
        vectorId: UUID? = nil,
        imagePath: String? = nil,
        title: String? = nil
    ) async throws -> Item {
        // 1. Create the SwiftData Item
        // Note: Init uses defaults for some fields, we set others after if needed
        let newItem = Item(
            timestamp: timestamp,
            content: content,
            title: title,
            appName: appName,
            contentType: contentType,
            imagePath: imagePath
        )
        newItem.tags = tags
        
        // 2. Add to Vector DB
        // If vectorId is provided, use it. Otherwise generate one.
        let finalVectorId = vectorId ?? UUID()
        newItem.vectorId = finalVectorId
        
        // Combine Title and Content for search embedding so both are searchable
        // Logic mirrored from ClipboardMonitor
        let embeddingText = (title != nil && !title!.isEmpty) ? "\(title!)\n\n\(content)" : content
        
        await vectorService.addDocument(vectorId: finalVectorId, text: embeddingText)
        
        // 3. Save to SwiftData
        modelContext.insert(newItem)
        
        // Note: Autosave is usually enabled, but we can force it if needed.
        // try modelContext.save()
        
        print("💾 [Repository] Saved item: \(title ?? "No Title") (ID: \(finalVectorId.uuidString))")
        return newItem
    }
    
    func deleteItem(_ item: Item) async throws {
        // 1. Remove from Vector DB
        if let vectorId = item.vectorId {
             // 1. Remove from Vector DB (Async)
             try? await vectorService.deleteDocument(vectorId: vectorId)
        }
        
        // 2. Remove from SwiftData
        modelContext.delete(item)
    }
    
    func updateItem(_ item: Item) async throws {
        // 1. Save SwiftData changes
        try modelContext.save()
        
        // 2. Update Vector DB
        if let vectorId = item.vectorId {
            let embeddingText = (item.title != nil && !item.title!.isEmpty) ? "\(item.title!)\n\n\(item.content)" : item.content
            
             // Clippy.addDocument overwrites if ID exists (upsert)
            await vectorService.addDocument(vectorId: vectorId, text: embeddingText)
            print("💾 [Repository] Updated item and re-indexed vector: \(item.title ?? "Untitled")")
        }
    }
    
    func findDuplicate(content: String) -> Item? {
        let fetchDescriptor = FetchDescriptor<Item>(
            predicate: #Predicate<Item> { item in
                item.content == content
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try? modelContext.fetch(fetchDescriptor).first
    }
}
