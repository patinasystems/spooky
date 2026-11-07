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
        var candidates = CommandPathCandidates.around(probe.text, byte: probe.hoverByte)
        if probe.kind == .localLink {
            guard let token = Self.localLinkPath(probe.uri) else { return nil }
            if let path = resolve(token: token, workingDirectory: probe.workingDirectory) {
                return CommandPathMatch(path: path, start: 0, length: probe.text.utf8.count)
            }
            // Some producers expand a short printed path against their cwd,
            // even when the prose explicitly names a different parent folder.
            if Self.isRelative(token) {
                candidates.insert(.init(token: token, start: 0, length: probe.text.utf8.count), at: 0)
            }
        } else {
            for candidate in candidates {
                if let path = resolveCandidate(candidate.token, workingDirectory: probe.workingDirectory) {
                    return CommandPathMatch(path: path, start: candidate.start, length: candidate.length)
                }
            }
        }

        // A bounded fallback, only after the literal target failed. Check at
        // most four explicitly printed directory paths; never search a tree.
        let parents = contextDirectories(probe)
        for candidate in candidates where Self.isRelative(candidate.token) {
            var match: CommandResolvedPath?
            for parent in parents {
                guard let path = resolveCandidate(candidate.token, workingDirectory: parent) else { continue }
                if let match, match.path != path.path { return nil }
                match = path
            }
            if let match { return CommandPathMatch(path: match, start: candidate.start, length: candidate.length) }
        }
        return nil
    }

    private func resolveCandidate(_ token: String, workingDirectory: String?) -> CommandResolvedPath? {
        if let path = resolve(token: token, workingDirectory: workingDirectory) { return path }
        guard let unescaped = CommandPathCandidates.unescape(token) else { return nil }
        return resolve(token: unescaped, workingDirectory: workingDirectory)
    }

    private func contextDirectories(_ probe: CommandPathProbe) -> [String] {
        guard probe.context.utf8.count <= 2_048 else { return [] }
        let punctuation = CharacterSet(charactersIn: "`\"'(),;:[]<>")
        var parents: [String] = []
        var inspected = 0
        for word in probe.context.split(whereSeparator: { $0.isWhitespace }).reversed() {
            let token = String(word).trimmingCharacters(in: punctuation)
            let linked = token.lowercased().hasPrefix("file:") ? Self.localLinkPath(token) : nil
            guard linked != nil || token.hasSuffix("/"), token != "/", token != "./",
                  linked != nil || !token.contains("://") else { continue }
            inspected += 1
            if let path = resolveCandidate(linked ?? token, workingDirectory: probe.workingDirectory), path.kind == .directory,
               !parents.contains(path.path) { parents.append(path.path) }
            if inspected == 4 { break }
        }
        return parents
    }

    nonisolated private static func isRelative(_ token: String) -> Bool {
        !token.hasPrefix("/") && !token.hasPrefix("~")
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
            expanded = workingDirectory + (workingDirectory.hasSuffix("/") ? "" : "/") + token
        }
        // Preserve `..`: collapsing it lexically would change the meaning
        // when an earlier component is a symlink. stat/Finder resolve it.
        return expanded
    }
}
