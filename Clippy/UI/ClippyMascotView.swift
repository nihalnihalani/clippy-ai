import SwiftUI

/// Always-visible animated Clippy mascot that overlays the main window content.
/// Draggable to any corner, with context menu to hide or reset.
struct ClippyMascotView: View {
    @ObservedObject var mascotState: ClippyMascotState
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private let mascotSize: CGFloat = 64
    private let padding: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            if mascotState.isVisible {
                MascotGifPlayer(gifName: mascotState.currentAnimation.gifFileName)
                    .frame(width: mascotSize, height: mascotSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .scaleEffect(isDragging ? 1.08 : 1.0)
                    .position(mascotPosition(in: geo.size))
                    .offset(dragOffset)
                    .gesture(dragGesture(in: geo.size))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                            mascotState.corner = .bottomRight
                        }
                    }
                    .contextMenu {
                        Button("Hide Mascot") { mascotState.toggleVisibility() }
                        Button("Reset Position") {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                mascotState.corner = .bottomRight
                            }
                        }
                        Divider()
                        Menu("Move to Corner") {
                            Button("Top Left") { mascotState.corner = .topLeft }
                            Button("Top Right") { mascotState.corner = .topRight }
                            Button("Bottom Left") { mascotState.corner = .bottomLeft }
                            Button("Bottom Right") { mascotState.corner = .bottomRight }
                        }
                    }
                    .accessibilityLabel("Clippy mascot")
                    .accessibilityHint("Double-click to reset position. Right-click for options.")
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.65), value: mascotState.corner)
            }
        }
    }

    // MARK: - Position

    private func mascotPosition(in size: CGSize) -> CGPoint {
        let halfSize = mascotSize / 2
        switch mascotState.corner {
        case .bottomRight:
            return CGPoint(x: size.width - halfSize - padding, y: size.height - halfSize - padding)
        case .bottomLeft:
            return CGPoint(x: halfSize + padding, y: size.height - halfSize - padding)
        case .topRight:
            return CGPoint(x: size.width - halfSize - padding, y: halfSize + padding)
        case .topLeft:
            return CGPoint(x: halfSize + padding, y: halfSize + padding)
        }
    }

    // MARK: - Drag Gesture (snap to nearest corner on release)

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                dragOffset = value.translation
            }
            .onEnded { value in
                isDragging = false
                let currentPos = mascotPosition(in: size)
                let finalX = currentPos.x + value.translation.width
                let finalY = currentPos.y + value.translation.height

                // Snap to nearest corner
                let midX = size.width / 2
                let midY = size.height / 2
                let newCorner: MascotCorner
                if finalX < midX {
                    newCorner = finalY < midY ? .topLeft : .bottomLeft
                } else {
                    newCorner = finalY < midY ? .topRight : .bottomRight
                }

                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    mascotState.corner = newCorner
                    dragOffset = .zero
                }
            }
    }
}
