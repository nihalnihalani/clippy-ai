import Foundation
import AppKit
import ApplicationServices

@MainActor
class TextCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var capturedText = ""
    @Published var captureStartTime: Date?
    
    // Dependencies
    private var clippyController: ClippyWindowController?
    private var clipboardMonitor: ClipboardMonitor?
    
    // Initialization of dependencies
    func setDependencies(clippyController: ClippyWindowController, clipboardMonitor: ClipboardMonitor) {
        self.clippyController = clippyController
        self.clipboardMonitor = clipboardMonitor
    }
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onCaptureComplete: ((String) -> Void)?
    private var onTypingDetected: (() -> Void)? // NEW: Callback when user starts typing
    private var capturedTextRange: NSRange?
    private var sourceApp: NSRunningApplication?  // Made var to allow clearing after replacement
    private var capturedTextLength: Int = 0  // Store length before capturedText is cleared
    private var hasTypedText: Bool = false  // NEW: Track if user has typed anything
    
    func startCapturing(onTypingDetected: (() -> Void)? = nil, onComplete: @escaping (String) -> Void) {
        guard !isCapturing else { return }
        
        self.onTypingDetected = onTypingDetected
        self.onCaptureComplete = onComplete
        self.isCapturing = true
        self.capturedText = ""
        self.capturedTextLength = 0
        self.hasTypedText = false  // Reset typing flag
        self.captureStartTime = Date()
        
        // Capture the source app immediately
        DispatchQueue.main.async {
            self.sourceApp = NSWorkspace.shared.frontmostApplication
            print("🎯 [TextCaptureService] Starting text capture...")
            print("   Source app: \(self.sourceApp?.localizedName ?? "Unknown")")
        }
        
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                let service = Unmanaged<TextCaptureService>.fromOpaque(refcon).takeUnretainedValue()
                
                // Check for Option+X to stop capturing
                if event.type == .keyDown && 
                   event.flags.contains(.maskAlternate) && 
                   event.getIntegerValueField(.keyboardEventKeycode) == 7 { // 7 = X
                    print("🎯 [TextCaptureService] Option+X detected - stopping capture")
                    DispatchQueue.main.async {
                        service.stopCapturing()
                    }
                    return nil // Consume event
                }
                
                // Capture text input events
                if event.type == .keyDown {
                    service.handleKeyEvent(event)
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("❌ [TextCaptureService] Failed to create event tap")
            return
        }
        
        self.eventTap = eventTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("✅ [TextCaptureService] Text capture started")
    }
    
    func stopCapturing() {
        guard isCapturing else { return }
        
        print("🛑 [TextCaptureService] Stopping text capture")
        print("   Captured text: '\(capturedText)'")
        print("   Capture duration: \(captureStartTime?.timeIntervalSinceNow ?? 0)s")
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        isCapturing = false
        hasTypedText = false  // Reset typing flag
        
        // Store the length BEFORE clearing capturedText
        capturedTextLength = capturedText.count
        print("   Stored captured text length: \(capturedTextLength) characters")
        
        // Call completion handler with captured text
        if !capturedText.isEmpty {
            onCaptureComplete?(capturedText)
        }
        
        // Reset state (but keep sourceApp and capturedTextLength for replacement)
        capturedText = ""
        captureStartTime = nil
        onCaptureComplete = nil
        onTypingDetected = nil  // Clear typing callback
        capturedTextRange = nil
        // Note: sourceApp and capturedTextLength are kept for replaceCapturedTextWithAnswer() and cleared there
    }
    
    private func handleKeyEvent(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        // Skip modifier-only keys
        if keyCode == 58 || keyCode == 61 || keyCode == 55 || keyCode == 56 || keyCode == 59 || keyCode == 60 {
            return
        }
        
        // Ignore Command or Control combinations (used for shortcuts)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return
        }
        
        // Handle special keys explicitly
        switch keyCode {
        case 36: // Return/Enter
            capturedText += "\n"
            return
        case 48: // Tab
            capturedText += "\t"
            return
        case 51: // Backspace
            if !capturedText.isEmpty {
                capturedText.removeLast()
            }
            return
        case 53: // Escape
            stopCapturing()
            return
        default:
            break
        }
        
        // Detect first keystroke (typing started)
        if !hasTypedText {
            hasTypedText = true
            print("⌨️ [TextCaptureService] User started typing - triggering callback")
            DispatchQueue.main.async {
                self.onTypingDetected?()
            }
        }
        
        if let extracted = extractText(from: event) {
            capturedText += extracted
        }
    }
    
    private func extractText(from event: CGEvent) -> String? {
        var length: Int = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
    
    /// Insert text using "Atomic Paste" (Clipboard Swap + Cmd+V) - The Industry Standard
    private func pasteTextAtomic(_ text: String) {
        print("🔄 [TextCaptureService] Performing Atomic Paste...")
        
        let pasteboard = NSPasteboard.general
        
        // 1. Backup current clipboard
        // Note: This is simplified. Preserving complex types exactly is hard.
        // We preserve just the string/image if possible or just use a temporary hold.
        // A robust implementation uses `pasteboardItems` array but restoring it perfectly is tricky.
        // For now, we backup the *string* content if any.
        let previousString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount
        
        // 2. Set new content
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // 3. Trigger Cmd+V
        simulateCmdV()
        
        // 4. Restore Clipboard (after delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("🔄 [TextCaptureService] Restoring clipboard...")
            if let oldText = previousString {
                // Only restore if user hasn't copied something else in the meantime
                if pasteboard.changeCount == previousChangeCount + 1 {
                    pasteboard.clearContents()
                    pasteboard.setString(oldText, forType: .string)
                } else {
                     print("⚠️ [TextCaptureService] Clipboard changed externally during paste, skipping restore")
                }
            } else {
                 // Nothing to restore (was empty or non-string). Clear?
                 // If it was image, we lost it with this simple impl.
                 // Ideally we shouldn't fail silently.

                 if pasteboard.changeCount == previousChangeCount + 1 {
                     pasteboard.clearContents() // Restore empty state
                 }
            }
        }
    }
    
    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // CMS+V Down
        if let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
            vDown.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
        }
        
        usleep(1000) // 1ms
        
        // CMD+V Up
        if let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            vUp.flags = .maskCommand
            vUp.post(tap: .cghidEventTap)
        }
    }
    


    /// Replace the captured text with the AI answer in the original text field
    func replaceCapturedTextWithAnswer(_ answer: String) {
        guard let currentSourceApp = sourceApp else {
            print("❌ [TextCaptureService] No source app available for replacement")
            return
        }
        
        print("🔄 [TextCaptureService] Replacing captured text with answer...")
        
        // Use Fluid Dictation's approach for deletion
        let src = CGEventSource(stateID: .hidSystemState)
        
        // Step 1: Delete the exact number of captured characters using backspace
        deleteCharacters(count: capturedTextLength, using: src)
        
        // Step 2: Wait for deletion to complete then Paste
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("🔄 [TextCaptureService] Deletion complete, pasting answer...")
            self.pasteTextAtomic(answer)
            
            // Clean up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.sourceApp = nil
                self.capturedTextLength = 0
                print("✅ [TextCaptureService] Text replacement complete")
            }
        }
    }
    
    /// Insert text into the current cursor position (for voice input or direct insertion)
    func insertTextAtCursor(_ answer: String) {
        print("🔄 [TextCaptureService] Inserting text at cursor position atomic...")
        pasteTextAtomic(answer)
    }

    /// Delete a specific number of characters using backspace events
    private func deleteCharacters(count: Int, using source: CGEventSource?) {
        print("🔄 [TextCaptureService] Deleting \(count) characters using backspace")
        guard count > 0 else { return }
        
        releaseModifierKeys(using: source)
        
        // Fast deletion loop
        for _ in 0..<count {
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true) {
                keyDown.post(tap: .cghidEventTap)
            }
            usleep(1000) // 1ms
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }
            usleep(1000)
        }
    }
    
    private func releaseModifierKeys(using source: CGEventSource?) {
        let modifierKeyCodes: [CGKeyCode] = [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3B]
        for code in modifierKeyCodes {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
