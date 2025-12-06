import SwiftUI
import AppKit
import ImageIO

struct ClippyGifPlayer: NSViewRepresentable {
    let gifName: String
    
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        return imageView
    }
    
    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Load GIF from the ClippyGifs folder
        // Filename format: clippy-white-X.gif
        
        print("🎬 ClippyGifPlayer: Updating view with \(gifName)")
        
        // We need to find the file path.
        // Since we added ClippyGifs as a folder reference, we look inside that bundle resource.
        
        // Try to load from Bundle (flat structure is standard for resources)
        if let url = Bundle.main.url(forResource: gifName, withExtension: "gif") {
            if let image = NSImage(contentsOf: url) {
                nsView.image = image
                nsView.animates = true
            } else {
                print("❌ ClippyGifPlayer: Failed to load image from \(url)")
            }
        } else {
            // Try with ClippyGifs subdirectory (if added as folder reference)
            if let url = Bundle.main.url(forResource: "ClippyGifs/\(gifName)", withExtension: "gif") {
                if let image = NSImage(contentsOf: url) {
                    nsView.image = image
                    nsView.animates = true
                }
            } else {
                print("❌ ClippyGifPlayer: GIF '\(gifName)' not found in bundle")
            }
        }
    }
}

