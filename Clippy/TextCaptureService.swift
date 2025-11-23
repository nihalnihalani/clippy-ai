import Foundation
import AppKit
import ApplicationServices

@MainActor
class TextCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var capturedText = ""
    @Published var captureStartTime: Date?
    
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
    
    /// Replace the captured text with the AI answer in the original text field
    func replaceCapturedTextWithAnswer(_ answer: String) {
        guard let currentSourceApp = sourceApp else {
            print("❌ [TextCaptureService] No source app available for replacement")
            return
        }
        
        print("🔄 [TextCaptureService] Replacing captured text with answer...")
        print("   Captured text length: \(capturedTextLength) characters")
        print("   Answer: \(answer.prefix(100))...")
        print("   Source app: \(currentSourceApp.localizedName ?? "Unknown")")
        
        // Use Fluid Dictation's approach with proper delays
        let src = CGEventSource(stateID: .hidSystemState)
        
        // Step 1: Delete the exact number of captured characters using backspace
        deleteCharacters(count: capturedTextLength, using: src)
        
        // Step 2: Wait for deletion to complete (like Fluid Dictation's 200ms delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("🔄 [TextCaptureService] Deletion complete, inserting answer...")
            
            // Step 3: Try the instant bulk CGEvent method first (Fluid Dictation's primary method)
            if self.insertTextBulkInstant(answer, using: src) {
                print("✅ [TextCaptureService] Text replaced via Fluid Dictation CGEvent method")
                self.sourceApp = nil
                self.capturedTextLength = 0
                return
            }
            
            print("⚠️ [TextCaptureService] CGEvent insertion failed, falling back to character-by-character")
            // Fallback to character-by-character typing (Fluid Dictation's fallback)
            self.typeTextCharByChar(answer, using: src)
            
            // Clear sourceApp and capturedTextLength after typing is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.sourceApp = nil
                self.capturedTextLength = 0
                print("✅ [TextCaptureService] Text replacement complete")
            }
        }
    }
    
    /// Insert text into the current cursor position (for voice input or direct insertion)
    func insertTextAtCursor(_ answer: String) {
        print("🔄 [TextCaptureService] Inserting text at cursor position (voice mode)...")
        print("   Answer: \(answer.prefix(100))...")
        
        let src = CGEventSource(stateID: .hidSystemState)
        
        // Try the instant bulk CGEvent method first (Fluid Dictation's primary method)
        if insertTextBulkInstant(answer, using: src) {
            print("✅ [TextCaptureService] Text inserted via Fluid Dictation CGEvent method")
            return
        }
        
        print("⚠️ [TextCaptureService] CGEvent insertion failed, falling back to character-by-character")
        // Fallback to character-by-character typing (Fluid Dictation's fallback)
        typeTextCharByChar(answer, using: src)
        print("✅ [TextCaptureService] Text insertion complete")
    }
    
    private func replaceTextUsingAccessibility(_ text: String, for application: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else {
            print("⚠️ [TextCaptureService] Accessibility permission not granted; cannot insert text directly")
            return false
        }
        
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        guard result == AXError.success else {
            print("⚠️ [TextCaptureService] Unable to locate focused UI element (AX result: \(result.rawValue))")
            return false
        }
        
        let focusedElement = focusedElementRef as! AXUIElement
        
        if let currentValue = axStringValue(of: focusedElement, attribute: kAXValueAttribute as CFString) {
            var range = CFRange(location: 0, length: currentValue.utf16.count)
            if let rangeValue = AXValueCreate(.cfRange, &range) {
                let selectionResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, rangeValue)
                if selectionResult != AXError.success {
                    print("⚠️ [TextCaptureService] Failed to select existing text (AX result: \(selectionResult.rawValue))")
                }
            }
        }
        
        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &isSettable) == AXError.success && isSettable.boolValue {
            let selectedResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if selectedResult == AXError.success {
                return true
            }
            print("⚠️ [TextCaptureService] Failed to set selected text (AX result: \(selectedResult.rawValue))")
        }
        
        isSettable = false
        if AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &isSettable) == AXError.success && isSettable.boolValue {
            let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, text as CFTypeRef)
            if setResult == AXError.success {
                return true
            }
            print("⚠️ [TextCaptureService] AX value insertion failed (AX result: \(setResult.rawValue))")
        }
        
        return false
    }
    
    private func axStringValue(of element: AXUIElement, attribute: CFString) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == AXError.success, let value = valueRef else { return nil }
        if let string = value as? String {
            return string
        }
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return nil
    }
    
    private func selectAllAndTypeAnswer(_ answer: String) {
        // Create a Cmd+A event to select all text
        let src = CGEventSource(stateID: .hidSystemState)
        
        releaseModifierKeys(using: src)
        
        // Cmd+A down
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) { // 0 = A
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        
        // Cmd+A up
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
        
        // Wait a moment for selection to complete, then type the answer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.typeTextCharByChar(answer, using: src)
            
            // Clear sourceApp after typing is complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.sourceApp = nil
                print("✅ [TextCaptureService] Text replacement complete")
            }
        }
    }
    
    /// Fluid Dictation's primary method: instant bulk CGEvent insertion
    private func insertTextBulkInstant(_ text: String, using source: CGEventSource?) -> Bool {
        print("🔄 [TextCaptureService] Starting Fluid Dictation INSTANT bulk CGEvent insertion (NO CLIPBOARD)")
        
        guard !text.isEmpty else {
            print("❌ [TextCaptureService] Empty text provided, aborting")
            return false
        }
        
        // Check accessibility permissions first
        guard AXIsProcessTrusted() else {
            print("❌ [TextCaptureService] Accessibility permissions required for text injection")
            return false
        }
        
        print("✅ [TextCaptureService] Accessibility check passed, proceeding with text injection")
        
        // Create single CGEvent with entire text - truly instant (exactly like Fluid Dictation)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            print("❌ [TextCaptureService] Failed to create bulk CGEvent")
            return false
        }
        
        // Convert entire text to UTF16
        let utf16Array = Array(text.utf16)
        print("🔄 [TextCaptureService] Converting \(text.count) characters to single CGEvent")
        
        // Set the entire text as unicode string
        event.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        
        // Post single event - INSTANT insertion (exactly like Fluid Dictation)
        event.post(tap: .cghidEventTap)
        print("✅ [TextCaptureService] Posted single CGEvent with entire text - INSTANT!")
        
        return true
    }
    
    /// Fluid Dictation's fallback method: character-by-character typing
    private func typeTextCharByChar(_ text: String, using source: CGEventSource?) {
        print("🔄 [TextCaptureService] Starting Fluid Dictation character-by-character typing")
        
        guard !text.isEmpty else {
            print("❌ [TextCaptureService] Empty text provided for character typing")
            return
        }
        
        // Check accessibility permissions first
        guard AXIsProcessTrusted() else {
            print("❌ [TextCaptureService] Accessibility permissions required for character typing")
            return
        }
        
        print("✅ [TextCaptureService] Typing \(text.count) characters one by one")
        
        // Fallback to character-by-character if bulk fails (exactly like Fluid Dictation)
        for (index, char) in text.enumerated() {
            if index % 10 == 0 {  // Log every 10th character to avoid spam
                print("🔄 [TextCaptureService] Typing character \(index+1)/\(text.count): '\(char)'")
            }
            typeCharacter(char, using: source)
            usleep(1000) // Small delay between characters (1ms) - exactly like Fluid Dictation
        }
        
        print("✅ [TextCaptureService] Character-by-character typing completed")
    }
    
    /// Type a single character using Fluid Dictation's method
    private func typeCharacter(_ char: Character, using source: CGEventSource?) {
        let charString = String(char)
        let utf16Array = Array(charString.utf16)
        
        // Create keyboard events for this character (exactly like Fluid Dictation)
        guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            print("❌ [TextCaptureService] Failed to create CGEvents for character: \(char)")
            return
        }
        
        // Set the unicode string for both events (exactly like Fluid Dictation)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        
        // Post the events (exactly like Fluid Dictation)
        keyDownEvent.post(tap: .cghidEventTap)
        usleep(2000) // Short delay between key down and up (2ms) - exactly like Fluid Dictation
        keyUpEvent.post(tap: .cghidEventTap)
    }
    
    /// Delete a specific number of characters using backspace events
    private func deleteCharacters(count: Int, using source: CGEventSource?) {
        print("🔄 [TextCaptureService] Deleting \(count) characters using backspace")
        
        guard count > 0 else {
            print("⚠️ [TextCaptureService] No characters to delete")
            return
        }
        
        // Release any modifier keys first to ensure clean state
        releaseModifierKeys(using: source)
        
        // Send backspace events for each character we captured
        // Using keycode 51 for backspace/delete
        for i in 0..<count {
            if i % 10 == 0 && i > 0 {  // Log every 10th deletion to avoid spam
                print("🔄 [TextCaptureService] Deleted \(i)/\(count) characters")
            }
            
            // Create backspace keyDown event
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true) {
                keyDown.post(tap: .cghidEventTap)
            }
            
            // Small delay between keyDown and keyUp (2ms like Fluid Dictation)
            usleep(2000)
            
            // Create backspace keyUp event
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                keyUp.post(tap: .cghidEventTap)
            }
            
            // Small delay between characters (1ms like Fluid Dictation)
            usleep(1000)
        }
        
        print("✅ [TextCaptureService] Deleted \(count) characters successfully")
    }
    
    private func releaseModifierKeys(using source: CGEventSource?) {
        let modifierKeyCodes: [CGKeyCode] = [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3B] // cmd, right cmd, shift, right shift, option, control
        for code in modifierKeyCodes {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
