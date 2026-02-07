import Foundation
import Combine
import os

// MARK: - Mascot Animation

/// Maps the 24 clippy_gif assets to semantic app states.
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

// MARK: - Mascot Corner

/// Which corner of the window the mascot snaps to.
enum MascotCorner: String {
    case bottomRight, bottomLeft, topRight, topLeft
}

// MARK: - ClippyMascotState

@MainActor
class ClippyMascotState: ObservableObject {
    // MARK: - Published State
    @Published private(set) var currentAnimation: MascotAnimation = .sleep
    @Published var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: "MascotVisible") }
    }
    @Published var corner: MascotCorner = .topRight {
        didSet { UserDefaults.standard.set(corner.rawValue, forKey: "MascotCorner") }
    }

    // MARK: - Idle cycling
    private var idleTimer: Timer?
    private let idleAnimations: [MascotAnimation] = [.whimsical, .music, .reading, .flying]
    private var idleIndex = 0
    private let idleCycleInterval: TimeInterval = 15.0

    // Deep idle
    private var lastActivityDate = Date()
    private let deepIdleThreshold: TimeInterval = 300 // 5 minutes

    // Transient animation return
    private var transientWorkItem: DispatchWorkItem?

    // MARK: - Combine
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        self.isVisible = UserDefaults.standard.object(forKey: "MascotVisible") as? Bool ?? true
        if let saved = UserDefaults.standard.string(forKey: "MascotCorner"),
           let c = MascotCorner(rawValue: saved) {
            self.corner = c
        }
    }

    // MARK: - Wiring (called from AppDependencyContainer.inject)

    func wire(clipboardMonitor: ClipboardMonitor, queryOrchestrator: QueryOrchestrator) {
        // Observe clipboard changes
        clipboardMonitor.$clipboardContent
            .dropFirst()
            .sink { [weak self] _ in self?.onClipboardChanged() }
            .store(in: &cancellables)

        // Observe AI processing
        queryOrchestrator.$isProcessing
            .removeDuplicates()
            .sink { [weak self] processing in
                if processing {
                    self?.onAIProcessingStarted()
                } else {
                    self?.onAIProcessingCompleted()
                }
            }
            .store(in: &cancellables)

        // Launch greeting then start idle cycling
        playAnimation(.hi, duration: 3.0, thenResume: true)
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

    private func onAIProcessingCompleted() {
        recordActivity()
        playAnimation(.celebrate, duration: 3.0, thenResume: true)
    }

    /// Called from ContentView when AI returns an error.
    func onAIError() {
        recordActivity()
        playAnimation(.angry, duration: 3.0, thenResume: true)
    }

    /// Called when user toggles a favorite.
    func onFavoriteToggled(isFavorite: Bool) {
        recordActivity()
        playAnimation(isFavorite ? .love : .dunno, duration: 2.0, thenResume: true)
    }

    /// Called when an item is deleted.
    func onItemDeleted() {
        recordActivity()
        playAnimation(.nauseous, duration: 2.0, thenResume: true)
    }

    /// Called when sensitive content is detected.
    func onSensitiveDetected() {
        recordActivity()
        playAnimation(.secret, duration: 2.5, thenResume: true)
    }

    /// Called when search overlay opens/closes.
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

    /// Called when voice recording is active.
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

    /// Called when settings sheet is opened.
    func onSettingsOpened() {
        recordActivity()
        playAnimation(.blushing, duration: 2.0, thenResume: true)
    }

    /// Called when OCR/vision capture triggers.
    func onVisionCapture() {
        recordActivity()
        playAnimation(.scared, duration: 2.0, thenResume: true)
    }

    // MARK: - Animation Control

    /// Play an animation for a duration, then optionally resume idle cycling.
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

        // Check for deep idle
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
            // Brief farewell before hiding
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.isVisible = false
                self?.stopIdleCycling()
            }
        } else {
            isVisible = true
            playAnimation(.hi, duration: 2.0, thenResume: true)
        }
    }
}
