import SwiftUI
import AppKit
import ApplicationServices

class ClippyWindowController: ObservableObject {
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var animationResetID = UUID()
    @Published var isVisible = false
    @Published var followTextInput = true // New property to enable/disable text input following
    @Published var currentState: ClippyAnimationState = .idle // Current animation state
    private var escapeKeyMonitor: Any? // Monitor for ESC key presses
    
    /// Set the current animation state and update the display
    func setState(_ state: ClippyAnimationState, message: String? = nil) {
        DispatchQueue.main.async {
            self.currentState = state
            let displayMessage = message ?? state.defaultMessage
            let gifName = state.gifFileName
            
            print("📎 [ClippyWindowController] Setting state to \(state) with GIF: \(gifName)")
            
            // Create window if needed
            if self.window == nil {
                print("📎 [ClippyWindowController] Creating new window")
                self.createWindow()
            }
            
                // Update the view content with new state
                self.hostingController?.rootView = AnyView(
                    ZStack(alignment: .topTrailing) {
                        ClippyGifPlayer(gifName: gifName)
                            .id(gifName) // FORCE VIEW REFRESH
                            .frame(width: 124, height: 93) // Standard Clippy size
                        
                        // Speech bubble with optional loading spinner
                        if !displayMessage.isEmpty || state == .thinking {
                            HStack(spacing: 6) {
                                // Show spinner during thinking state
                                if state == .thinking {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 12, height: 12)
                                }
                                
                                if !displayMessage.isEmpty {
                                    Text(displayMessage)
                                }
                            }
                            .padding(8)
                            .background(state == .error ? Color.red.opacity(0.9) : Color.yellow.opacity(0.9))
                            .cornerRadius(8)
                            .foregroundColor(.black)
                            .font(.caption)
                            .offset(x: -100, y: -50) // Offset to left of Clippy
                        }
                    }
                )
            
            // Position near text input if enabled (do this BEFORE showing)
            // Only reposition if window is not already visible to allow user to drag it
            if !self.isVisible {
                if self.followTextInput {
                    self.positionNearActiveTextInput()
                } else {
                    // Fallback to centered position
                    if let window = self.window {
                        self.positionWindowCentered(window)
                    }
                }
            }
            
            // Show the window
            self.window?.orderFrontRegardless()
            self.isVisible = true
            
            print("📎 [ClippyWindowController] Window positioned and visible")
            
            // Start monitoring for ESC key when window is shown
            self.startEscapeKeyMonitoring()
            
            // Auto-hide after 'done' state (after 2 seconds)
            if state == .done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.hide()
                }
            }
        }
    }
    
    func hide() {
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.isVisible = false
            self.currentState = .idle // Reset to idle state
            
            // Stop monitoring ESC key when window is hidden
            self.stopEscapeKeyMonitoring()
            self.animationResetID = UUID()
        }
    }
    

    
    private func createWindow() {
        // Create the hosting controller
        // Initial view is empty/placeholder until show() is called
        self.hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        
        hostingController?.view.wantsLayer = true
        hostingController?.view.layer?.backgroundColor = NSColor.clear.cgColor
        
        // Create the window (sized for 124x93 Clippy animation)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 124, height: 93),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = window, let hostingController = hostingController else { return }
        
        // Configure window properties
        window.contentViewController = hostingController
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        // Ensure content view is transparent
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        
        // Position will be set when show() is called
        positionWindowCentered(window)
        
        // Window is ready but not shown yet
        window.alphaValue = 1.0
        
        print("📎 [ClippyWindowController] Window created and ready")
    }
    
    // MARK: - Public Methods
    
    /// Toggle whether the clippy follows the active text input
    func setFollowTextInput(_ enabled: Bool) {
        followTextInput = enabled
        print("🐕 [ClippyWindowController] Text input following: \(enabled ? "enabled" : "disabled")")
    }
    
    /// Manually reposition the clippy near the current text input (if following is enabled)
    func repositionNearTextInput() {
        guard followTextInput else { return }
        positionNearActiveTextInput()
    }
    
    // MARK: - Text Input Positioning
    
    /// Position the clippy window near the currently active text input element
    private func positionNearActiveTextInput() {
        guard let window = window else { return }
        
        if let textInputFrame = getActiveTextInputFrame() {
            positionWindow(window, nearTextInput: textInputFrame)
        } else {
            // Fallback to default positioning if no text input is found
            positionWindowDefault(window)
        }
    }
    
    /// Get the frame (position and size) of the currently focused text input element
    private func getActiveTextInputFrame() -> NSRect? {
        guard AXIsProcessTrusted() else {
            print("⚠️ [ClippyWindowController] Accessibility permission not granted")
            return nil
        }
        
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            print("⚠️ [ClippyWindowController] No frontmost application")
            return nil
        }
        
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        
        guard result == AXError.success, let focusedElement = focusedElementRef else {
            print("⚠️ [ClippyWindowController] Unable to locate focused UI element")
            return nil
        }
        
        let focusedUIElement = focusedElement as! AXUIElement
        
        // Check if the focused element is a text input (text field, text area, etc.)
        if !isTextInputElement(focusedUIElement) {
            print("ℹ️ [ClippyWindowController] Focused element is not a text input")
            return nil
        }
        
        // Try to get the exact caret position first
        if let caretFrame = getCaretPosition(focusedUIElement) {
            print("✅ [ClippyWindowController] Found caret at: \(caretFrame)")
            return caretFrame
        }
        
        // Fallback to text field bounds if caret position is not available
        guard let position = getElementPosition(focusedUIElement),
              let size = getElementSize(focusedUIElement) else {
            print("⚠️ [ClippyWindowController] Unable to get text input position/size")
            return nil
        }
        
        let frame = NSRect(x: position.x, y: position.y, width: size.width, height: size.height)
        print("✅ [ClippyWindowController] Found text input at: \(frame) (fallback to field bounds)")
        return frame
    }
    
    /// Check if the given accessibility element is a text input
    private func isTextInputElement(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        
        guard roleResult == AXError.success, let role = roleRef as? String else {
            return false
        }
        
        // Common text input roles
        let textInputRoles = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole
        ]
        
        return textInputRoles.contains { $0 as String == role }
    }
    
    /// Get the position of an accessibility element
    private func getElementPosition(_ element: AXUIElement) -> NSPoint? {
        var positionRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        
        guard result == AXError.success, let positionValue = positionRef else {
            return nil
        }
        
        var point = NSPoint()
        let success = AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        return success ? point : nil
    }
    
    /// Get the size of an accessibility element
    private func getElementSize(_ element: AXUIElement) -> NSSize? {
        var sizeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        
        guard result == AXError.success, let sizeValue = sizeRef else {
            return nil
        }
        
        var size = NSSize()
        let success = AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return success ? size : nil
    }
    
    /// Get the exact position of the text caret/cursor
    private func getCaretPosition(_ element: AXUIElement) -> NSRect? {
        // First, get the selected text range (which indicates the caret position)
        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)
        
        guard rangeResult == AXError.success, let selectedRangeValue = selectedRangeRef else {
            print("⚠️ [ClippyWindowController] Unable to get selected text range")
            return nil
        }
        
        // Get the bounds for the selected range (caret position)
        var caretBoundsRef: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeValue,
            &caretBoundsRef
        )
        
        guard boundsResult == AXError.success, let caretBoundsValue = caretBoundsRef else {
            print("⚠️ [ClippyWindowController] Unable to get caret bounds")
            return nil
        }
        
        var caretBounds = CGRect()
        let success = AXValueGetValue(caretBoundsValue as! AXValue, .cgRect, &caretBounds)
        
        if success {
            // Convert CGRect to NSRect and return
            return NSRect(x: caretBounds.origin.x, y: caretBounds.origin.y, width: max(caretBounds.width, 2), height: caretBounds.height)
        } else {
            print("⚠️ [ClippyWindowController] Failed to extract caret bounds from AXValue")
            return nil
        }
    }
    
    /// Position the clippy window in a fixed location - horizontally centered, just below screen center
    private func positionWindow(_ window: NSWindow, nearTextInput textInputFrame: NSRect) {
        positionWindowCentered(window)
    }
    
    /// Fallback positioning when no text input is found
    private func positionWindowDefault(_ window: NSWindow) {
        positionWindowCentered(window)
    }
    
    /// Position the clippy window in the top-right area of the screen, away from the notch
    private func positionWindowCentered(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        
        let windowSize = window.frame.size
        let screenFrame = screen.visibleFrame // Use visible frame to avoid menu bar and dock
        
        // Position in top-right area with some padding from the edges
        let padding: CGFloat = 20
        let x = screenFrame.maxX - windowSize.width - padding
        let y = screenFrame.maxY - windowSize.height - padding
        
        let newOrigin = NSPoint(x: x, y: y)
        window.setFrameOrigin(newOrigin)
        
        print("🐕 [ClippyWindowController] Positioned clippy in top-right at: \(newOrigin)")
    }
    
    // MARK: - ESC Key Monitoring
    
    /// Start monitoring for ESC key presses to dismiss the clippy
    private func startEscapeKeyMonitoring() {
        // Stop any existing monitor first
        stopEscapeKeyMonitoring()
        
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Check if ESC key was pressed (keyCode 53)
            if event.keyCode == 53 {
                print("🐕 [ClippyWindowController] ESC key pressed - hiding clippy")
                self?.hide()
            }
        }
        
        print("🐕 [ClippyWindowController] Started ESC key monitoring")
    }
    
    /// Stop monitoring for ESC key presses
    private func stopEscapeKeyMonitoring() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
            print("🐕 [ClippyWindowController] Stopped ESC key monitoring")
        }

        // Reset animation when dismissing the clippy so it restarts next time it's shown
        animationResetID = UUID()
    }
    
    deinit {
        stopEscapeKeyMonitoring()
        window?.close()
    }
}

