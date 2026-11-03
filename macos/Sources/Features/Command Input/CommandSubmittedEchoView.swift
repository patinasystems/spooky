import AppKit

/// A short-lived native text presentation across the AppKit/Metal handoff.
/// It owns no completion/history behavior, focus, accessibility, or events.
@MainActor
final class CommandSubmittedEchoView: NSView {
    /// A presentation aid must not duplicate an arbitrarily large TextKit
    /// document on the submission path. Larger commands fail open to Metal.
    static let maximumBytes = 16_384
    private let storage: NSTextStorage
    private let scrollView = NSScrollView()
    private let textView: NSTextView

    override var isFlipped: Bool { true }
    var displayedText: String { textView.string }

    init() {
        let storage = NSTextStorage()
        self.storage = storage
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.setAccessibilityElement(false)
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.setAccessibilityElement(false)
        addSubview(scrollView)
        setAccessibilityElement(false)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }

    @discardableResult
    func retainPresentation(from editor: CommandInputView, background: NSColor) -> Bool {
        let measurement = CommandInputDiagnostics.begin(.submissionEchoCopy)
        defer { CommandInputDiagnostics.end(measurement) }
        guard editor.textView.string.utf8.count <= Self.maximumBytes else { clear(); return false }
        frame = editor.frame
        layer?.backgroundColor = background.cgColor
        appearance = editor.appearance
        scrollView.frame = editor.scrollView.frame
        textView.frame = editor.textView.frame
        textView.minSize = editor.textView.minSize
        textView.maxSize = editor.textView.maxSize
        textView.font = editor.textView.font
        textView.textColor = editor.textView.textColor
        textView.defaultParagraphStyle = editor.textView.defaultParagraphStyle
        textView.textContainerInset = editor.textView.textContainerInset
        if let source = editor.textView.textContainer, let target = textView.textContainer {
            target.widthTracksTextView = source.widthTracksTextView
            target.heightTracksTextView = source.heightTracksTextView
            target.containerSize = source.containerSize
            target.lineFragmentPadding = source.lineFragmentPadding
        }
        storage.setAttributedString(editor.textView.attributedString())
        scrollView.contentView.scroll(to: editor.scrollView.contentView.bounds.origin)
        isHidden = false
        return true
    }

    func clear() {
        isHidden = true
        storage.setAttributedString(NSAttributedString(string: ""))
    }
}
