/// Keep the best-effort empty-prompt presentation gate adjacent to the widget
/// trigger. Refused admission must never prevent ordinary shell submission.
enum CommandSubmissionGate {
    static func dispatch(text: String, begin: () -> Bool, cancel: () -> Void, trigger: () -> Bool) -> Bool {
        if text.isEmpty { _ = begin() }
        guard trigger() else { cancel(); return false }
        return true
    }
}
