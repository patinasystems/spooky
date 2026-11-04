import Foundation

/// Bounded hints from evaluated _arguments specs, never a shell evaluator.
/// Unknown specification forms keep their completion candidates without hints.
struct CommandCompletionMetadata {
    private struct Option {
        let description: String
        let argument: String
    }
    private var options: [String: Option] = [:]
    private let valueOption: String?

    init(specs: [String], request: CommandCompletionRequest) {
        let range = CommandCompletionToken.range(in: request.text, cursorUTF16: request.cursorUTF16)
        let prefix = (range.map { (request.text as NSString).substring(to: $0.location) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        valueOption = CommandCompletionToken.range(in: prefix, cursorUTF16: prefix.utf16.count)
            .map { (prefix as NSString).substring(with: $0) }
        for spec in specs {
            var body = spec[...]
            while body.first == "*" || body.first == "!" { body = body.dropFirst() }
            if body.first == "(", let end = body.firstIndex(of: ")") { body = body[body.index(after: end)...] }
            while body.first == "*" || body.first == "!" { body = body.dropFirst() }
            guard body.first == "-" || body.first == "+" else { continue }
            let headEnd = Self.delimiter(in: body, characters: "[:") ?? body.endIndex
            var name = String(body[..<headEnd])
            while name.count > 2, let last = name.last, "=-+".contains(last) { name.removeLast() }
            guard !name.contains(where: { $0.isWhitespace }), name.count > 1 else { continue }
            var tail = body[headEnd...]
            var description = ""
            if tail.first == "[" {
                tail = tail.dropFirst()
                guard let end = Self.delimiter(in: tail, characters: "]") else { continue }
                description = Self.clean(String(tail[..<end]))
                tail = tail[tail.index(after: end)...]
            }
            var argument = ""
            if tail.first == ":" {
                while tail.first == ":" { tail = tail.dropFirst() }
                let end = Self.delimiter(in: tail, characters: ":") ?? tail.endIndex
                argument = Self.clean(String(tail[..<end]))
                let action = end == tail.endIndex ? "" : String(tail[tail.index(after: end)...])
                if argument.isEmpty {
                    if action == "_files" { argument = "file" }
                    if action == "_directories" { argument = "directory" }
                }
                if action.first == "(", action.last == ")", !action.dropFirst().contains("("),
                   !action.contains(where: { "'\"\\$`".contains($0) }) {
                    let choices = action.dropFirst().dropLast().split(whereSeparator: { $0.isWhitespace }).joined(separator: " | ")
                    if !choices.isEmpty { argument += argument.isEmpty ? choices : ": " + choices }
                }
            }
            options[name] = Option(description: description, argument: Self.clean(argument))
        }
    }

    func detail(for label: String) -> String {
        let token = CommandCompletionToken.unquoted(label)
        let name = String(token.prefix(while: { $0 != "=" }))
        var option = options[name]
        if option == nil, name.hasPrefix("-"), !name.hasPrefix("--"), name.count > 2, let last = name.last {
            option = options["-" + String(last)]
        }
        if let option {
            return [option.argument.isEmpty ? "" : "⟨\(option.argument)⟩", option.description]
                .filter { !$0.isEmpty }.joined(separator: "  ")
        }
        if let valueOption, let option = options[valueOption], !option.argument.isEmpty {
            return "⟨\(option.argument)⟩"
        }
        return ""
    }

    /// Git's Bash-backed provider supplies names without descriptions. Its
    /// installed, version-matched manual can fill those hints without running
    /// another completer or changing candidates. Never execute roff macros.
    func needsGitManual(for labels: [String]) -> Bool {
        labels.contains { $0.hasPrefix("-") && detail(for: $0).isEmpty }
            || (valueOption?.hasPrefix("-") == true && options[valueOption ?? ""] == nil)
    }

    mutating func addGitManual(_ text: String, matching labels: [String]? = nil) {
        var remaining = labels.map { Set($0.filter { $0.hasPrefix("-") }
            .map { String($0.prefix(while: { $0 != "=" })) }) }
        if let valueOption, valueOption.hasPrefix("-") { remaining?.insert(valueOption) }
        if remaining?.isEmpty == true { return }
        guard let font = try? NSRegularExpression(pattern: #"\\f(?:\[[^\]]*\]|\(..|.)"#),
              let flag = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9-])(--?[A-Za-z0-9][A-Za-z0-9-]*)(?:\[?=?\s*(<[^>]+>))?"#) else { return }
        func plain(_ line: String) -> String {
            var value = font.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: line.utf16.count),
                                                       withTemplate: "")
            for (escaped, literal) in [(#"\-"#, "-"), (#"\&"#, ""), (#"\:"#, ""),
                                        (#"\(aq"#, "'"), (#"\(cq"#, "’"), (#"\(dq"#, "\""),
                                        (#"\(em"#, "—"), (#"\~"#, " ")] {
                value = value.replacingOccurrences(of: escaped, with: literal)
            }
            return value
        }
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count, options.count < 2048 {
            guard lines[index] == ".PP" else { index += 1; continue }
            index += 1
            var heading = ""
            while index < lines.count, !lines[index].hasPrefix(".RS"), !lines[index].hasPrefix(".") {
                heading += plain(lines[index]) + " "
                index += 1
                if heading.utf16.count > 2048 { break }
            }
            guard heading.first == "-", index < lines.count, lines[index].hasPrefix(".RS") else { continue }
            let value = heading as NSString
            let matches = flag.matches(in: heading, range: NSRange(location: 0, length: value.length)).filter {
                remaining == nil || remaining?.contains(value.substring(with: $0.range(at: 1))) == true
            }
            guard !matches.isEmpty else { continue }
            index += 1
            var description = ""
            while index < lines.count, !lines[index].hasPrefix(".") {
                description += plain(lines[index]) + " "
                index += 1
                if description.utf16.count > 512 { break }
            }
            for match in matches {
                let name = value.substring(with: match.range(at: 1))
                remaining?.remove(name)
                let argument = match.range(at: 2).location == NSNotFound ? "" :
                    value.substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                guard options[name] == nil else { continue }
                options[name] = Option(description: Self.clean(description), argument: Self.clean(argument))
            }
            if remaining?.isEmpty == true { return }
        }
    }

    private static func delimiter(in text: Substring, characters: String) -> String.Index? {
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if characters.contains(character) { return index }
        }
        return nil
    }

    private static func clean(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\\:", with: ":")
            .replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]")
            .components(separatedBy: .controlCharacters).joined(separator: " ").prefix(512))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
