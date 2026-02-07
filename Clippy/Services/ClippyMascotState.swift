import Foundation
import Combine
import os

// MARK: - Mascot Animation

/// Maps the clippy_gif assets to semantic app states.
/// Raw values are the exact GIF filenames (case-sensitive) without extension.
enum MascotAnimation: String, CaseIterable {
    // Greetings / transitions
    case hi
    case bye
    case pop

    // Activity states
    case reading  = "Reading"
    case thinking = "Thinking"
    case whimsical

    // Success / celebration
    case celebrate
    case complete

    // Reactions
    case love
    case blushing
    case lol
    case music
    case angry
    case crying
    case nauseous
    case scared
    case wtf
    case dunno
    case secret
    case devil
    case kiss

    // Idle / ambient
    case sleep
    case flying
    case superman

    /// The GIF filename (without extension) as it exists in clippy_gif/
    var gifFileName: String { rawValue }
}

// MARK: - Mascot Activity State

/// Semantic activity states that bridge the old ClippyAnimationState API.
/// ContentView calls `mascotState.setState(.thinking, message: "...")`.
enum MascotActivityState {
    case idle
    case writing
    case thinking
    case done
    case error

    var animation: MascotAnimation {
        switch self {
        case .idle:     return .whimsical
        case .writing:  return .reading
        case .thinking: return .thinking
        case .done:     return .complete
        case .error:    return .angry
        }
    }

    var defaultMessage: String {
        switch self {
        case .idle:     return "Listening..."
        case .writing:  return "Got it..."
        case .thinking: return "Thinking..."
        case .done:     return "Done!"
        case .error:    return "Oops! Something went wrong"
        }
    }
}

// MARK: - ClippyMascotState

@MainActor
class ClippyMascotState: ObservableObject {
    // MARK: - Published State
    @Published private(set) var currentAnimation: MascotAnimation = .sleep
    @Published var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: "MascotVisible") }
    }

    // MARK: - Message Bubble
    @Published var currentMessage: String?
    @Published var showSpinner: Bool = false

    // MARK: - Free Drag Position (percentage of container, 0.0–1.0)
    @Published var positionX: CGFloat {
        didSet { UserDefaults.standard.set(Double(positionX), forKey: "MascotPositionX") }
    }
    @Published var positionY: CGFloat {
        didSet { UserDefaults.standard.set(Double(positionY), forKey: "MascotPositionY") }
    }

    // MARK: - Idle cycling
    private var idleTimer: Timer?
    private let idleAnimations: [MascotAnimation] = [.whimsical, .music, .reading, .flying]
    private var idleIndex = 0
    private let idleCycleInterval: TimeInterval = 15.0

    // Deep idle
    private var lastActivityDate = Date()
    private let deepIdleThreshold: TimeInterval = 300

    // Timers
    private var transientWorkItem: DispatchWorkItem?
    private var messageDismissWorkItem: DispatchWorkItem?

    // MARK: - Combine
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        self.isVisible = UserDefaults.standard.object(forKey: "MascotVisible") as? Bool ?? true

        let x = UserDefaults.standard.double(forKey: "MascotPositionX")
        let y = UserDefaults.standard.double(forKey: "MascotPositionY")
        // Default to top-right area
        self.positionX = x == 0 ? 0.92 : CGFloat(x)
        self.positionY = y == 0 ? 0.08 : CGFloat(y)
    }

    // MARK: - Wiring (called from AppDependencyContainer.inject)

    func wire(clipboardMonitor: ClipboardMonitor, queryOrchestrator: QueryOrchestrator) {
        clipboardMonitor.$clipboardContent
            .dropFirst()
            .sink { [weak self] _ in self?.onClipboardChanged() }
            .store(in: &cancellables)

        queryOrchestrator.$isProcessing
            .removeDuplicates()
            .sink { [weak self] processing in
                if processing {
                    self?.onAIProcessingStarted()
                }
                // Don't auto-handle completion here — ContentView's setState(.done) handles it
            }
            .store(in: &cancellables)

        playAnimation(.hi, duration: 3.0, thenResume: true)
    }

    // MARK: - setState (replaces ClippyWindowController.setState)

    /// Bridge method replacing ClippyWindowController.setState(_:message:).
    /// Sets the mascot animation and displays an optional message bubble.
    func setState(_ state: MascotActivityState, message: String? = nil) {
        cancelTransient()
        stopIdleCycling()
        recordActivity()

        currentAnimation = state.animation
        currentMessage = message ?? state.defaultMessage
        showSpinner = (state == .thinking)

        messageDismissWorkItem?.cancel()

        switch state {
        case .done:
            let item = DispatchWorkItem { [weak self] in
                self?.currentMessage = nil
                self?.showSpinner = false
                self?.startIdleCycling()
            }
            messageDismissWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)

        case .error:
            let item = DispatchWorkItem { [weak self] in
                self?.currentMessage = nil
                self?.showSpinner = false
                self?.startIdleCycling()
            }
            messageDismissWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)

        case .idle, .writing, .thinking:
            break // Persistent until next state change
        }
    }

    /// Dismiss the current message and return to idle cycling.
    /// Replaces ClippyWindowController.hide().
    func dismissMessage() {
        messageDismissWorkItem?.cancel()
        currentMessage = nil
        showSpinner = false
        startIdleCycling()
    }

    // MARK: - Event Handlers

    private func onClipboardChanged() {
        recordActivity()
        playAnimation(.flying, duration: 2.0, thenResume: true)
    }

    private func onAIProcessingStarted() {
        recordActivity()
        cancelTransient()
        stopIdleCycling()
        currentAnimation = .thinking
    }

    func onAIError() {
        recordActivity()
        playAnimation(.angry, duration: 3.0, thenResume: true)
    }

    func onFavoriteToggled(isFavorite: Bool) {
        recordActivity()
        playAnimation(isFavorite ? .love : .dunno, duration: 2.0, thenResume: true)
    }

    func onItemDeleted() {
        recordActivity()
        playAnimation(.nauseous, duration: 2.0, thenResume: true)
    }

    func onSensitiveDetected() {
        recordActivity()
        playAnimation(.secret, duration: 2.5, thenResume: true)
    }

    func onSearchOverlay(opened: Bool) {
        recordActivity()
        if opened {
            cancelTransient()
            stopIdleCycling()
            currentAnimation = .superman
        } else {
            playAnimation(.bye, duration: 2.0, thenResume: true)
        }
    }

    func onVoiceRecording(active: Bool) {
        recordActivity()
        if active {
            cancelTransient()
            stopIdleCycling()
            currentAnimation = .music
        } else {
            startIdleCycling()
        }
    }

    func onSettingsOpened() {
        recordActivity()
        playAnimation(.blushing, duration: 2.0, thenResume: true)
    }

    func onVisionCapture() {
        recordActivity()
        playAnimation(.scared, duration: 2.0, thenResume: true)
    }

    // MARK: - Animation Control

    func playAnimation(_ animation: MascotAnimation, duration: TimeInterval, thenResume: Bool) {
        cancelTransient()
        stopIdleCycling()
        currentAnimation = animation

        if thenResume {
            let item = DispatchWorkItem { [weak self] in
                self?.startIdleCycling()
            }
            transientWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
        }
    }

    // MARK: - Idle Cycling

    func startIdleCycling() {
        stopIdleCycling()

        if Date().timeIntervalSince(lastActivityDate) > deepIdleThreshold {
            currentAnimation = .sleep
        } else {
            currentAnimation = idleAnimations[idleIndex]
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: idleCycleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if Date().timeIntervalSince(self.lastActivityDate) > self.deepIdleThreshold {
                    self.currentAnimation = .sleep
                } else {
                    self.idleIndex = (self.idleIndex + 1) % self.idleAnimations.count
                    self.currentAnimation = self.idleAnimations[self.idleIndex]
                }
            }
        }
    }

    private func stopIdleCycling() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func cancelTransient() {
        transientWorkItem?.cancel()
        transientWorkItem = nil
    }

    private func recordActivity() {
        lastActivityDate = Date()
    }

    // MARK: - Visibility

    func toggleVisibility() {
        if isVisible {
            currentAnimation = .bye
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.isVisible = false
                self?.stopIdleCycling()
            }
        } else {
            isVisible = true
            playAnimation(.hi, duration: 2.0, thenResume: true)
        }
    }

    /// Reset position to default (top-right).
    func resetPosition() {
        positionX = 0.92
        positionY = 0.08
    }
}
