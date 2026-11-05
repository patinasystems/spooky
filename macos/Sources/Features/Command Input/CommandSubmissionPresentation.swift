/// One presentation barrier per submitted draft. The existing native editor
/// and completion overlay stay unchanged until the matching command/newline
/// image is attached. No copied text view, timeout, or second display clock.
struct CommandSubmissionPresentation {
    private(set) var blockID: String?
    private var waitsForPrompt = false
    private var presentedSerial: UInt64 = 0

    mutating func begin(blockID: String, empty: Bool) {
        self.blockID = blockID
        waitsForPrompt = empty
    }

    /// A nonempty command commits at its real C frame. An empty submission
    /// retains the caret through C/D/A and commits only with a fresh B frame.
    @discardableResult
    mutating func presented(blockID: String?, serial: UInt64, readyPromptID: String?) -> Bool {
        guard serial > presentedSerial else { return false }
        presentedSerial = serial
        guard let pending = self.blockID else { return false }
        let nextPrompt = readyPromptID.map { !$0.isEmpty && $0 != pending } ?? false
        guard nextPrompt || (!waitsForPrompt && blockID == pending) else { return false }
        return cancel()
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let wasHolding = blockID != nil
        blockID = nil
        return wasHolding
    }
}
