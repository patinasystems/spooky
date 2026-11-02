import AppKit
import SwiftUI

/// The command editor is separate from the terminal grid. Only its owner can
/// clear an acknowledged submission or hand input back to the running program.
@MainActor
struct CommandInputView: View {
    @Binding var text: String
    var isEditable: Bool
    var focusRequest: UInt64 = 0
    var onSubmit: (String) -> Bool
    var onUseTerminal: () -> Void
    var onFocusChanged: (Bool) -> Void

    @State private var editorHeight: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            CommandEditorRepresentable(
                text: $text,
                isEditable: isEditable,
                focusRequest: focusRequest,
                onSubmit: onSubmit,
                onUseTerminal: onUseTerminal,
                onFocusChanged: onFocusChanged,
                onContentHeightChanged: { editorHeight = min(186, max(76, $0)) }
            )
            .frame(height: editorHeight)

            HStack {
                Text(isEditable ? "Return to run · Shift Return for a new line" : "Waiting for the shell…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use Terminal", action: onUseTerminal)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Return keyboard input to the terminal (Escape)")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

@MainActor
private struct CommandEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var focusRequest: UInt64
    var onSubmit: (String) -> Bool
    var onUseTerminal: () -> Void
    var onFocusChanged: (Bool) -> Void
    var onContentHeightChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = CommandEditorScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = CommandTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 76), textContainer: nil)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandTextView else { return }
        context.coordinator.parent = self
        update(textView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? CommandTextView else { return }
        if textView.window?.firstResponder === textView {
            coordinator.parent.onFocusChanged(false)
        }
        textView.focusRequested = false
        textView.delegate = nil
        textView.onFocusChanged = { _ in }
        textView.onContentHeightChanged = { _ in }
    }

    private func update(_ textView: CommandTextView, coordinator: Coordinator) {
        textView.onSubmit = onSubmit
        textView.onUseTerminal = onUseTerminal
        textView.onFocusChanged = onFocusChanged
        textView.onContentHeightChanged = { [weak coordinator] height in
            coordinator?.contentHeightChanged(height)
        }
        textView.isEditable = isEditable
        textView.isSelectable = true

        // Replacing string on every SwiftUI update destroys native selection,
        // marked text, and undo grouping. Only accept an actual external edit.
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            if text.isEmpty { textView.undoManager?.removeAllActions() }
            textView.reportContentHeight()
        }

        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            textView.focusRequested = focusRequest != 0
        }
        textView.applyFocusRequest()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandEditorRepresentable
        var lastFocusRequest: UInt64 = 0
        private var lastHeight: CGFloat = 0

        init(_ parent: CommandEditorRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CommandTextView else { return }
            parent.text = textView.string
        }

        func contentHeightChanged(_ height: CGFloat) {
            guard lastHeight != height else { return }
            lastHeight = height
            // Layout may run during updateNSView; publish size on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.onContentHeightChanged(self.lastHeight)
            }
        }
    }
}

/// Keep the document covering the viewport even when TextKit lays out an empty
/// string. Otherwise clicking below its only line hits NSClipView, not the editor.
@MainActor
final class CommandEditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? CommandTextView else { return }
        let viewportHeight = contentView.bounds.height
        guard viewportHeight > 0 else { return }
        if textView.minSize.height != viewportHeight {
            textView.minSize = NSSize(width: 0, height: viewportHeight)
        }
        if textView.frame.height < viewportHeight {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: viewportHeight))
        }
    }
}
