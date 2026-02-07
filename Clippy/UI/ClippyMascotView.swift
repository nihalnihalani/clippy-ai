import SwiftUI

/// Always-visible animated Clippy mascot that overlays the main window content.
/// Draggable to any corner, with context menu to hide or reset.
struct ClippyMascotView: View {
    @ObservedObject var mascotState: ClippyMascotState
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private let mascotSize: CGFloat = 64

    var body: some View {
        if mascotState.isVisible {
            mascotBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cornerAlignment)
                .padding(12)
                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: mascotState.corner)
                .allowsHitTesting(true)
        }
    }

    private var mascotBody: some View {
        MascotGifPlayer(gifName: mascotState.currentAnimation.gifFileName)
            .frame(width: mascotSize, height: mascotSize)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .scaleEffect(isDragging ? 1.08 : 1.0)
            .offset(dragOffset)
            .gesture(dragGesture)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    mascotState.corner = .topRight
                }
            }
            .contextMenu {
                Button("Hide Mascot") { mascotState.toggleVisibility() }
                Button("Reset Position") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                        mascotState.corner = .topRight
                    }
                }
                Divider()
                Menu("Move to Corner") {
                    Button("Top Left") { mascotState.corner = .topLeft }
                    Button("Top Right") { mascotState.corner = .topRight }
                    Button("Bottom Left") { mascotState.corner = .bottomLeft }
                    Button("Bottom Right") { mascotState.corner = .topRight }
                }
            }
            .accessibilityLabel("Clippy mascot")
            .accessibilityHint("Double-click to reset position. Right-click for options.")
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Corner Alignment

    private var cornerAlignment: Alignment {
        switch mascotState.corner {
        case .bottomRight: return .bottomTrailing
        case .bottomLeft:  return .bottomLeading
        case .topRight:    return .topTrailing
        case .topLeft:     return .topLeading
        }
    }

    // MARK: - Drag Gesture (snap to nearest corner on release)

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                isDragging = false
                let dx = value.translation.width
                let dy = value.translation.height

                // Determine new corner from drag direction
                var newCorner = mascotState.corner
                let threshold: CGFloat = 50

                if abs(dx) > threshold || abs(dy) > threshold {
                    let goingRight = dx > threshold
                    let goingLeft = dx < -threshold
                    let goingDown = dy > threshold
                    let goingUp = dy < -threshold

                    switch mascotState.corner {
                    case .bottomRight:
                        if goingLeft { newCorner = .bottomLeft }
                        if goingUp { newCorner = .topRight }
                        if goingLeft && goingUp { newCorner = .topLeft }
                    case .bottomLeft:
                        if goingRight { newCorner = .bottomRight }
                        if goingUp { newCorner = .topLeft }
                        if goingRight && goingUp { newCorner = .topRight }
                    case .topRight:
                        if goingLeft { newCorner = .topLeft }
                        if goingDown { newCorner = .bottomRight }
                        if goingLeft && goingDown { newCorner = .bottomLeft }
                    case .topLeft:
                        if goingRight { newCorner = .topRight }
                        if goingDown { newCorner = .bottomLeft }
                        if goingRight && goingDown { newCorner = .bottomRight }
                    }
                }

                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    mascotState.corner = newCorner
                    dragOffset = .zero
                }
            }
    }
}
