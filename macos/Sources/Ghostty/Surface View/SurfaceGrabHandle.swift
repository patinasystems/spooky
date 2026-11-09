import SwiftUI

extension Ghostty {
    /// A grab handle overlay at the top of the surface for dragging a surface.
    struct SurfaceGrabHandle: View {
        // Size of the actual drag handle; the hover reveal region is larger.
        private static let handleSize = CGSize(width: 56, height: 20)

        // Reveal the handle anywhere within the top % of the pane height.
        private static let hoverHeightFactor: CGFloat = 0.2

        @ObservedObject var surfaceView: SurfaceView
        let dragHandle: Ghostty.Config.DragHandle
        let isSplit: Bool

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        private var handleVisible: Bool {
            // AppKit applies the window-count policy without rebuilding this
            // SwiftUI wrapper whenever another window opens/closes.
            dragHandle != .never
        }

        private var gripVisible: Bool {
            switch dragHandle {
            case .always:
                return true
            case .never:
                return false
            case .auto:
                break
            }
            // If the cursor isn't visible, never show the handle
            guard surfaceView.cursorVisible else { return false }
            // If we're hovering or actively dragging, always visible
            if isHovering || isDragging { return true }

            // Require our mouse location to be within the top area of the
            // surface.
            guard let mouseLocation = surfaceView.mouseLocationInSurface else { return false }
            return Self.isInHoverRegion(mouseLocation, in: surfaceView.bounds)
        }

        var body: some View {
            if handleVisible {
                SurfaceDragSource(
                    surfaceView: surfaceView,
                    showsGrip: gripVisible,
                    isSplit: isSplit,
                    isDragging: $isDragging,
                    isHovering: $isHovering
                )
                .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                .contentShape(Rectangle())
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }

        /// Reveal near the pane’s top-right edge, away from the command text.
        private static func hoverRect(in bounds: CGRect) -> CGRect {
            guard !bounds.isEmpty else { return .zero }

            let hoverHeight = min(bounds.height, max(handleSize.height, bounds.height * hoverHeightFactor))
            return CGRect(
                x: max(bounds.minX, bounds.maxX - handleSize.width - 12),
                y: bounds.maxY - hoverHeight,
                width: min(bounds.width, handleSize.width + 12),
                height: hoverHeight
            )
        }

        /// Returns true when the pointer is inside the top hover band.
        private static func isInHoverRegion(_ point: CGPoint, in bounds: CGRect) -> Bool {
            hoverRect(in: bounds).contains(point)
        }
    }
}
