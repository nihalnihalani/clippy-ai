import AppKit
import SwiftUI
import Combine

// MARK: - Floating NSPanel

/// Borderless, always-on-top panel that hosts the Clippy mascot GIF + speech bubble.
/// Never steals focus from the user's active app. Draggable anywhere on screen.
class FloatingMascotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }
}

// MARK: - Floating Mascot Controller

/// Manages the floating mascot panel lifecycle, observes ClippyMascotState,
/// and handles position persistence in absolute screen coordinates.
@MainActor
class FloatingMascotController: NSObject {
    private var panel: FloatingMascotPanel?
    private var cancellables = Set<AnyCancellable>()
    private let mascotState: ClippyMascotState
    private let mascotSize: CGFloat = 128

    // UserDefaults keys for absolute screen position
    private let posXKey = "FloatingMascotScreenX"
    private let posYKey = "FloatingMascotScreenY"

    init(mascotState: ClippyMascotState) {
        self.mascotState = mascotState
        super.init()
        setupPanel()
        observeState()
        observeScreenChanges()
        observePanelDrag()
    }

    // MARK: - Panel Setup

    private func setupPanel() {
        let panelWidth: CGFloat = 240
        let panelHeight: CGFloat = 200
        let panel = FloatingMascotPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        )
        self.panel = panel

        let contentView = FloatingMascotContentView(mascotState: mascotState, mascotSize: mascotSize)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView = hostingView

        // Right-click context menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Hide Mascot", action: #selector(hideMascot), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Position", action: #selector(resetPositionAction), keyEquivalent: ""))
        panel.contentView?.menu = menu
        // Set the controller as the target for menu actions
        for item in menu.items { item.target = self }

        restorePosition()

        if mascotState.isVisible {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Context Menu Actions

    @objc private func hideMascot() {
        mascotState.toggleVisibility()
    }

    @objc private func resetPositionAction() {
        moveToDefaultPosition()
    }

    // MARK: - Combine Observation

    private func observeState() {
        // Show/hide panel when visibility changes
        mascotState.$isVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible {
                    self?.panel?.orderFrontRegardless()
                } else {
                    self?.panel?.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // Resize panel when message appears/disappears
        mascotState.$currentMessage
            .sink { [weak self] message in
                self?.resizePanelForContent(hasMessage: message != nil)
            }
            .store(in: &cancellables)
    }

    private func resizePanelForContent(hasMessage: Bool) {
        guard let panel = panel else { return }
        let newHeight: CGFloat = hasMessage ? 220 : mascotSize + 20
        let newWidth: CGFloat = hasMessage ? 240 : mascotSize + 20
        var frame = panel.frame
        // Grow upward (macOS coordinates: origin is bottom-left)
        let deltaH = newHeight - frame.height
        frame.origin.y -= deltaH
        frame.size = NSSize(width: newWidth, height: newHeight)
        panel.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Drag Position Persistence

    private func observePanelDrag() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.persistPosition()
        }
    }

    // MARK: - Position Persistence

    private func restorePosition() {
        let x = UserDefaults.standard.double(forKey: posXKey)
        let y = UserDefaults.standard.double(forKey: posYKey)

        if x == 0 && y == 0 {
            moveToDefaultPosition()
        } else {
            let point = NSPoint(x: x, y: y)
            if isPointOnScreen(point) {
                panel?.setFrameOrigin(point)
            } else {
                moveToDefaultPosition()
            }
        }
    }

    private func moveToDefaultPosition() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - (mascotSize + 40),
            y: visibleFrame.maxY - (mascotSize + 60)
        )
        panel?.setFrameOrigin(origin)
        persistPosition()
    }

    private func persistPosition() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set(Double(origin.x), forKey: posXKey)
        UserDefaults.standard.set(Double(origin.y), forKey: posYKey)
    }

    private func isPointOnScreen(_ point: NSPoint) -> Bool {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) { return true }
        }
        return false
    }

    // MARK: - Screen Change Handling

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let origin = self.panel?.frame.origin else { return }
            if !self.isPointOnScreen(origin) {
                self.moveToDefaultPosition()
            }
        }
    }
}

// MARK: - Floating Mascot SwiftUI Content

/// The SwiftUI view hosted inside the floating NSPanel.
/// Simpler than the old ClippyMascotView — no GeometryReader or hit-testing hacks needed.
struct FloatingMascotContentView: View {
    @ObservedObject var mascotState: ClippyMascotState
    let mascotSize: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            // Speech bubble
            if let message = mascotState.currentMessage {
                HStack(spacing: 5) {
                    if mascotState.showSpinner {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(.primary)
                    }
                    Text(message)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: message)
            }

            // Mascot GIF
            MascotGifPlayer(gifName: mascotState.currentAnimation.gifFileName)
                .frame(width: mascotSize, height: mascotSize)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
