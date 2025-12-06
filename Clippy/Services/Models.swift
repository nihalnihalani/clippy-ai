import Foundation
import SwiftData

// MARK: - Item Model

@Model
final class Item {
    var timestamp: Date
    var content: String
    var title: String? // Added for structured content (e.g., Vision titles)
    var appName: String?
    var contentType: String
    var usageCount: Int
    var vectorId: UUID?
    var tags: [String] // AI-generated semantic tags for better retrieval
    var imagePath: String? // Path to saved image file (for image clipboard items)
    var isFavorite: Bool = false
    
    init(timestamp: Date, content: String = "", title: String? = nil, appName: String? = nil, contentType: String = "text", imagePath: String? = nil, isFavorite: Bool = false) {
        self.timestamp = timestamp
        self.content = content
        self.title = title
        self.appName = appName
        self.contentType = contentType
        self.usageCount = 0
        self.tags = []
        self.imagePath = imagePath
        self.isFavorite = isFavorite
    }
}

// MARK: - Clippy Animation State

/// Represents the different animation states for the Clippy character
enum ClippyAnimationState {
    case idle      // User pressed Option+X, waiting for input
    case writing   // User is typing text
    case thinking  // AI is processing the query (minimum 3 seconds)
    case done      // AI has completed processing
    case error     // An error occurred (API failure, etc.)
    
    /// The GIF file name for this animation state
    var gifFileName: String {
        switch self {
        case .idle:
            return "clippy-idle"
        case .writing:
            return "clippy-writing"
        case .thinking:
            return "clippy-thinking"
        case .done:
            return "clippy-done"
        case .error:
            return "clippy-idle" // Use idle animation for errors
        }
    }
    
    /// Default message to display for this state
    var defaultMessage: String {
        switch self {
        case .idle:
            return "Listening..."
        case .writing:
            return "Got it..."
        case .thinking:
            return "Thinking..."
        case .done:
            return "Done!"
        case .error:
            return "Oops! Something went wrong"
        }
    }
}
