import Foundation

struct CommandResolvedPath: Equatable, Sendable {
    enum Kind: Sendable { case file, directory }
    let path: String
    let kind: Kind
}

/// Filesystem validation never runs on the UI actor. A small, expiring cache
/// prevents repeated stat calls as the pointer crosses cells of the same path.
/// Both positive and negative results expire, so files created by a command
/// become available without a persistent directory watcher.
actor CommandPathResolver {
    private struct Entry {
        let path: String
        let result: CommandResolvedPath?
        let expires: TimeInterval
    }

    private let inspect: @Sendable (String) -> CommandResolvedPath.Kind?
    private let now: @Sendable () -> TimeInterval
    private let home: String
    private let capacity: Int
    private var entries: [Entry] = []
    private var replacement = 0

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         capacity: Int = 128,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         inspect: @escaping @Sendable (String) -> CommandResolvedPath.Kind? = { path in
             var directory: ObjCBool = false
             guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return nil }
             return directory.boolValue ? .directory : .file
         }) {
        self.home = home
        self.capacity = max(1, min(128, capacity))
        self.now = now
        self.inspect = inspect
    }

    func match(_ probe: CommandPathProbe) -> CommandPathMatch? {
        guard !Task.isCancelled else { return nil }
        if probe.kind == .header {
            guard let cwd = probe.workingDirectory,
                  let path = resolve(token: cwd, workingDirectory: nil, trustedDirectory: true) else { return nil }
            return CommandPathMatch(path: path, start: 0, length: probe.text.utf8.count)
        }
        if probe.kind == .localLink {
            guard let token = Self.localLinkPath(probe.uri),
                  let path = resolve(token: token, workingDirectory: probe.workingDirectory) else { return nil }
            return CommandPathMatch(path: path, start: 0, length: probe.text.utf8.count)
        }
        for candidate in CommandPathCandidates.around(probe.text, byte: probe.hoverByte) {
            if let path = resolve(token: candidate.token, workingDirectory: probe.workingDirectory) {
                return CommandPathMatch(path: path, start: candidate.start, length: candidate.length)
            }
            if let token = CommandPathCandidates.unescape(candidate.token),
               let path = resolve(token: token, workingDirectory: probe.workingDirectory) {
                return CommandPathMatch(path: path, start: candidate.start, length: candidate.length)
            }
        }
        return nil
    }

    func resolve(token: String, workingDirectory: String?, trustedDirectory: Bool = false) -> CommandResolvedPath? {
        guard !Task.isCancelled,
              let path = Self.absolutePath(token: token, workingDirectory: workingDirectory, home: home) else { return nil }
        // Header metadata already contains the shell's exact cwd. It remains
        // useful to copy even if a subsequent command removes that directory.
        if trustedDirectory { return CommandResolvedPath(path: path, kind: .directory) }
        let time = now()
        if let entry = entries.first(where: { $0.path == path && $0.expires > time }) { return entry.result }
        guard !Task.isCancelled else { return nil }
        let result = inspect(path).map { CommandResolvedPath(path: path, kind: $0) }
        guard !Task.isCancelled else { return nil }
        let entry = Entry(path: path, result: result, expires: time + (result == nil ? 0.5 : 2))
        if let index = entries.firstIndex(where: { $0.path == path }) {
            entries[index] = entry
        } else if entries.count < capacity {
            entries.append(entry)
        } else {
            entries[replacement] = entry
            replacement = (replacement + 1) % capacity
        }
        return result
    }

    /// OSC 8 labels need not contain their target's spelling. Resolve the
    /// decoded local target against its owning block, just like printed paths.
    /// Never let Foundation fill in a relative file URL from the app's cwd.
    nonisolated static func localLinkPath(_ uri: String) -> String? {
        guard !uri.hasPrefix("//"),
              let components = URLComponents(string: uri),
              components.scheme == nil || components.scheme?.lowercased() == "file",
              components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
              components.user == nil, components.password == nil, components.port == nil,
              !components.path.isEmpty else { return nil }
        return components.path
    }

    /// Lexical only: no shell expansion, command execution, symlink resolution,
    /// or guessing relative paths from today's prompt for historic output.
    nonisolated static func absolutePath(token: String, workingDirectory: String?, home: String) -> String? {
        guard !token.isEmpty, token.utf8.count <= 4_096, !token.utf8.contains(0) else { return nil }
        let expanded: String
        if token == "~" { expanded = home } else if token.hasPrefix("~/") { expanded = home + token.dropFirst() } else if token.hasPrefix("/") { expanded = token } else {
            guard let workingDirectory, workingDirectory.hasPrefix("/"),
                  workingDirectory.utf8.count <= 16_384, !workingDirectory.utf8.contains(0) else { return nil }
            expanded = workingDirectory + "/" + token
        }
        // Preserve `..`: collapsing it lexically would change the meaning
        // when an earlier component is a symlink. stat/Finder resolve it.
        return expanded
    }
}
