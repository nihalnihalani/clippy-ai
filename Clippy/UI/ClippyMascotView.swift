import SwiftUI

/// Always-visible animated Clippy mascot that overlays the main window content.
/// Freely draggable anywhere within the window. Shows message bubbles for status.
struct ClippyMascotView: View {
    @ObservedObject var mascotState: ClippyMascotState
    @State private var isDragging = false

    private let mascotSize: CGFloat = 64

    var body: some View {
        if mascotState.isVisible {
            GeometryReader { geo in
                mascotBody
                    .position(
                        x: mascotState.positionX * geo.size.width,
                        y: mascotState.positionY * geo.size.height
                    )
                    .gesture(freeDragGesture(in: geo.size))
            }
            .allowsHitTesting(false)
            .overlay {
                // Invisible hit target at the mascot's position for drag/click
                GeometryReader { geo in
                    Color.clear
                        .frame(width: mascotSize + 16, height: mascotSize + 16)
                        .contentShape(Rectangle())
                        .position(
                            x: mascotState.positionX * geo.size.width,
                            y: mascotState.positionY * geo.size.height
                        )
                        .gesture(freeDragGesture(in: geo.size))
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                mascotState.resetPosition()
                            }
                        }
                        .contextMenu {
                            Button("Hide Mascot") { mascotState.toggleVisibility() }
                            Button("Reset Position") {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                    mascotState.resetPosition()
                                }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Mascot Body + Speech Bubble

    private var mascotBody: some View {
        VStack(spacing: 4) {
            // Message bubble (above mascot)
            if let message = mascotState.currentMessage {
                HStack(spacing: 5) {
                    if mascotState.showSpinner {
                        ProgressView()
                            .scaleEffect(0.55)
                            .tint(.primary)
                    }
                    Text(message)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
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
                .scaleEffect(isDragging ? 1.08 : 1.0)
        }
        .accessibilityLabel("Clippy mascot")
        .accessibilityHint("Double-click to reset position. Right-click for options.")
    }

    // MARK: - Free Drag Gesture

    private func freeDragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                let newX = max(0.05, min(0.95, value.location.x / size.width))
                let newY = max(0.05, min(0.95, value.location.y / size.height))
                mascotState.positionX = newX
                mascotState.positionY = newY
            }
            .onEnded { _ in
                isDragging = false
            }
    }
}
