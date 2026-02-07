import SwiftUI
import AppKit

/// Renders an animated GIF from the clippy_gif/ bundle subfolder.
/// Uses NSImageView with `.animates = true` for native GIF frame animation.
/// Only the active GIF is loaded — previous images are released by ARC on swap.
struct MascotGifPlayer: NSViewRepresentable {
    let gifName: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.isEditable = false
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Respect reduce-motion accessibility setting
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Search clippy_gif/ subdirectory first, then root Resources
        let searchPaths: [URL?] = [
            Bundle.main.url(forResource: gifName, withExtension: "gif", subdirectory: "clippy_gif"),
            Bundle.main.url(forResource: gifName, withExtension: "gif")
        ]

        for case let url? in searchPaths {
            if let image = NSImage(contentsOf: url) {
                nsView.image = image
                nsView.animates = !reduceMotion
                return
            }
        }

        // Fallback: show a paperclip icon if GIF not found
        nsView.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Clippy")
        nsView.animates = false
    }
}
