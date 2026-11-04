import Darwin
import Foundation

/// Identity of the local user and machine hosting the native zsh session.
/// Read once without DNS; never infer a remote identity from terminal output.
struct CommandPromptIdentity: Equatable, Sendable {
    let label: String

    init?(username: String, hostname: String) {
        // Match zsh's usual %n@%m: the login name and short machine name.
        let host = hostname.prefix { $0 != "." }
        guard !username.isEmpty, !host.isEmpty,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        label = "\(username)@\(host)"
    }

    static let local: Self? = {
        // Reserve an extra NUL even if the platform returns a full buffer.
        var bytes = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        let result = bytes.withUnsafeMutableBufferPointer {
            gethostname($0.baseAddress, $0.count - 1)
        }
        guard result == 0 else { return nil }
        return Self(username: NSUserName(), hostname: String(cString: bytes))
    }()
}
