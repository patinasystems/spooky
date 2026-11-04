import AppKit

/// The text system owns editing/selection/IME. A single layer owns the thin
/// caret so moving an empty prompt and attaching its terminal image can commit
/// together, without NSTextView's separately scheduled insertion indicator.
@MainActor
final class CommandInputCaret {
    let layer = CALayer()
    private weak var editor: CommandInputView?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(editor: CommandInputView) {
        self.editor = editor
        layer.isHidden = true
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
                         "opacity": NSNull(), "backgroundColor": NSNull()]
        layer.zPosition = 1
        editor.layer?.addSublayer(layer)
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func attach(to window: NSWindow?) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.update(restart: true) } })
            }
        }
        update(restart: true)
    }

    /// Uses NSTextInputClient's own caret rectangle, including wrapped lines,
    /// tabs, Unicode and marked text. No parallel glyph-layout implementation.
    static func frame(textView: CommandTextView, in container: NSView) -> NSRect? {
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound, selection.length == 0, let window = textView.window else { return nil }
        let screen = textView.firstRect(forCharacterRange: selection, actualRange: nil)
        guard screen.height > 0, screen.minX.isFinite, screen.minY.isFinite else { return nil }
        var rect = container.convert(window.convertFromScreen(screen), from: nil)
        let scale = max(1, window.backingScaleFactor)
        rect.origin.x = (rect.origin.x * scale).rounded() / scale
        rect.size.width = 1
        let viewport = container.convert(textView.visibleRect, from: textView)
        let clipped = rect.intersection(viewport)
        return clipped.isEmpty ? nil : clipped
    }

    func update(restart: Bool = false) {
        guard let editor, let window = editor.window, window.isKeyWindow,
              window.occlusionState.contains(.visible), !editor.isHiddenOrHasHiddenAncestor,
              editor.textView.isEditable, window.firstResponder === editor.textView,
              let frame = Self.frame(textView: editor.textView, in: editor) else {
            layer.isHidden = true
            timer?.invalidate()
            timer = nil
            return
        }
        let moved = layer.frame != frame
        if moved { layer.frame = frame }
        layer.backgroundColor = editor.textView.insertionPointColor.cgColor
        layer.isHidden = false
        if restart || moved || timer == nil {
            layer.opacity = 1
            if let timer { timer.fireDate = Date(timeIntervalSinceNow: 0.5) } else {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.layer.opacity = self.layer.opacity == 0 ? 1 : 0
                    }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
}
