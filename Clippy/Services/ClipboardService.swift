import SwiftUI
import SwiftData
import AppKit

class ClipboardService {
    static let shared = ClipboardService()
    
    private init() {}
    
    func getImagesDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Clippy/Images")
    }
    
    func loadImage(from path: String) -> NSImage? {
        let imageURL = getImagesDirectory().appendingPathComponent(path)
        return NSImage(contentsOf: imageURL)
    }
    
    func copyImageToClipboard(imagePath: String) {
        let imageURL = getImagesDirectory().appendingPathComponent(imagePath)
        
        guard let nsImage = NSImage(contentsOf: imageURL) else {
            print("❌ Failed to load image from disk")
            return
        }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        
        print("✅ Image copied to clipboard")
    }
    
    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
    


