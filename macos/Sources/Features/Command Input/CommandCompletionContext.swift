import Foundation

/// Display and cached filtering only. Zsh still owns parsing, quoting, and the
/// exact replacement buffer; this scanner never evaluates shell input.
enum CommandCompletionToken {
    static func range(in text: String, cursorUTF16: Int) -> NSRange? {
        guard CommandCompletionBridge.byteOffset(in: text, cursorUTF16: cursorUTF16) != nil else { return nil }
        var start: Int?
        var quote: UInt16?
        var escaped = false
        for (index, unit) in text.utf16.enumerated() {
            let separator = quote == nil && !escaped && isSeparator(unit)
            if separator {
                if let begin = start, (begin...index).contains(cursorUTF16) {
                    return NSRange(location: begin, length: index - begin)
                }
                start = nil
            } else {
                if start == nil { start = index }
                if escaped {
                    escaped = false
                } else if unit == 92 && quote != 39 {
                    escaped = true
                } else if unit == quote {
                    quote = nil
                } else if quote == nil && (unit == 39 || unit == 34) {
                    quote = unit
                }
            }
        }
        if let start, cursorUTF16 >= start {
            return NSRange(location: start, length: text.utf16.count - start)
        }
        return NSRange(location: cursorUTF16, length: 0)
    }

    static func label(result: String, cursorUTF16: Int, request: CommandCompletionRequest) -> String {
        let resultValue = result as NSString
        let option: String
        if let range = range(in: request.text, cursorUTF16: request.cursorUTF16),
           let replacement = replacement(in: result, original: request.text, range: range) {
            option = replacement
        } else {
            var cursor = min(cursorUTF16, resultValue.length)
            while cursor > 0, [9, 10, 13, 32].contains(resultValue.character(at: cursor - 1)) { cursor -= 1 }
            let range = range(in: result, cursorUTF16: cursor) ?? NSRange(location: 0, length: 0)
            option = resultValue.substring(with: range)
        }
        let label = unquoted(option.trimmingCharacters(in: .whitespacesAndNewlines))
        return label.isEmpty ? "(empty option)" : String(label.prefix(240))
    }

    static func replacement(in result: String, original: String, range: NSRange) -> String? {
        let original = original as NSString
        let prefix = original.substring(to: range.location)
        let suffix = original.substring(from: NSMaxRange(range))
        return replacement(in: result, prefix: prefix, suffix: suffix)
    }

    static func replacement(in result: String, prefix: String, suffix: String) -> String? {
        let value = result as NSString
        let start = prefix.utf16.count
        let length = value.length - (prefix as NSString).length - (suffix as NSString).length
        guard length >= 0,
              value.substring(to: start).utf16.elementsEqual(prefix.utf16),
              value.substring(from: start + length).utf16.elementsEqual(suffix.utf16) else { return nil }
        let replacementRange = NSRange(location: start, length: length)
        guard CommandCompletionBridge.byteOffset(in: result, cursorUTF16: replacementRange.location) != nil,
              CommandCompletionBridge.byteOffset(in: result, cursorUTF16: NSMaxRange(replacementRange)) != nil else {
            return nil
        }
        return value.substring(with: replacementRange)
    }

    static func unquoted(_ text: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                if quote == "\"", !"$`\"\\\n".contains(character) { result.append("\\") }
                if character != "\n" { result.append(character) }
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if character == quote {
                quote = nil
            } else if quote == nil && (character == "'" || character == "\"") {
                quote = character
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func isSeparator(_ unit: UInt16) -> Bool {
        [9, 10, 13, 32, 59, 124, 38, 40, 41, 60, 62].contains(unit)
    }
}

/// A broader, nonexecuting shell query supplies candidates for local fuzzy
/// matching. Unsupported shell constructs keep using the exact user draft.
struct CommandCompletionQuery: Sendable, Equatable {
    let text: String
    let cursorUTF16: Int

    static func broadened(text: String, cursorUTF16: Int) -> CommandCompletionQuery? {
        guard let range = CommandCompletionToken.range(in: text, cursorUTF16: cursorUTF16) else { return nil }
        let value = text as NSString
        let prefix = value.substring(to: range.location)
        let suffix = value.substring(from: NSMaxRange(range))
        guard let command = commandPosition(after: prefix),
              let token = simpleToken(value.substring(with: range)) else { return nil }
        let body = token.body as NSString
        let caret = min(cursorUTF16 - range.location - token.open.utf16.count, body.length)
        guard caret >= 0 else { return nil }
        let beforeCaret = body.substring(to: caret)
        // A caret inside an earlier path component needs shell-specific suffix
        // handling; preserve that exact query instead of inventing a path.
        guard !body.substring(from: caret).contains("/") else { return nil }
        let slash = (beforeCaret as NSString).range(of: "/", options: .backwards)
        let directoryLength = slash.location == NSNotFound ? 0 : NSMaxRange(slash)
        var component = body.substring(to: directoryLength)
        if !command, directoryLength == 0, beforeCaret.hasPrefix("-") {
            // Preserve option context for compsys/_arguments. An empty broad
            // token can instead ask the shell for positional arguments/files.
            component = beforeCaret.hasPrefix("--") ? "--" : "-"
        }
        if command {
            // The shell caps results at 200. Keeping one typed character avoids
            // enumerating the entire command universe and dropping most names.
            let typed = (beforeCaret as NSString).substring(from: directoryLength)
            guard let first = typed.first else { return nil }
            component.append(first)
        }
        let queryToken = token.open + component + token.close
        return .init(text: prefix + queryToken + suffix,
                     cursorUTF16: prefix.utf16.count + token.open.utf16.count + component.utf16.count)
    }

    private struct SimpleToken {
        let open: String
        let body: String
        let close: String
    }

    private static func simpleToken(_ text: String) -> SimpleToken? {
        let opening = text.first
        let quote: Character? = opening == "'" || opening == "\"" ? opening : nil
        var body = ""
        var closed = false
        var escaped = false
        for character in quote == nil ? text[...] : text.dropFirst() {
            guard !closed, character != "\n", character != "\r" else { return nil }
            if escaped {
                body.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                body.append(character)
                escaped = true
                continue
            }
            if character == quote { closed = true; continue }
            if quote == nil, "'\"$`*?[]{}()=".contains(character) { return nil }
            if quote == "\"", character == "$" || character == "`" { return nil }
            body.append(character)
        }
        guard !escaped else { return nil }
        return SimpleToken(open: quote.map(String.init) ?? "", body: body,
                           close: closed ? quote.map(String.init) ?? "" : "")
    }

    private static func commandPosition(after prefix: String) -> Bool? {
        var quote: Character?
        var escaped = false
        var inWord = false
        var words = 0
        var firstWord = ""
        for character in prefix {
            if escaped {
                if words == 1 { firstWord.append(character) }
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                if !inWord { words += 1; inWord = true }
                escaped = true
                continue
            }
            if character == quote { quote = nil; continue }
            if quote == "'" {
                if words == 1 { firstWord.append(character) }
                continue
            }
            if "$`()<>={}".contains(character) { return nil }
            if quote == nil, ";|&\n".contains(character) {
                words = 0
                firstWord = ""
                inWord = false
                continue
            }
            if quote == nil, character == " " || character == "\t" { inWord = false; continue }
            if !inWord {
                if character == "#" { return nil }
                words += 1
                inWord = true
            }
            if quote == nil, character == "'" || character == "\"" { quote = character; continue }
            if words == 1 { firstWord.append(character) }
        }
        guard quote == nil, !escaped else { return nil }
        let complex = ["sudo", "command", "builtin", "exec", "env", "noglob", "nocorrect", "time",
                       "if", "then", "else", "for", "while", "case", "function", "repeat", "do"]
        guard !complex.contains(firstWord) else { return nil }
        return words == 0
    }
}

/// Results may be reused only while the unchanged command prefix and suffix
/// still surround one active token. Accepting always replaces its current range.
struct CommandCompletionFilter {
    private struct IndexedCandidate {
        let candidate: CommandCompletionCandidate
        let normalized: [UInt32]
    }
    private let prefix: String
    private let suffix: String
    private let candidates: [IndexedCandidate]
    private let locale: Locale

    init?(request: CommandCompletionRequest, items: [CommandCompletionCandidate]) {
        guard let range = CommandCompletionToken.range(in: request.text, cursorUTF16: request.cursorUTF16),
              !items.isEmpty else { return nil }
        let value = request.text as NSString
        let prefix = value.substring(to: range.location)
        let suffix = value.substring(from: NSMaxRange(range))
        let locale = Locale.current
        var candidates: [IndexedCandidate] = []
        candidates.reserveCapacity(items.count)
        for item in items {
            let result = (request.text as NSString).replacingCharacters(in: item.replacementRange, with: item.replacementText)
            guard let replacement = CommandCompletionToken.replacement(in: result, prefix: prefix, suffix: suffix) else {
                // One completion function may return a broader command edit.
                // Never let that disable validation for the other candidates:
                // retain only edits confined to this active token.
                continue
            }
            let candidate = CommandCompletionCandidate(
                displayText: item.displayText, detail: item.detail, replacementText: replacement,
                replacementRange: range, cursorUTF16: item.cursorUTF16 ??
                    item.replacementRange.location + item.replacementText.utf16.count)
            // Match the complete shell token, not the display label's 240-character
            // preview. Unicode folding and token decoding happen once per result.
            candidates.append(.init(candidate: candidate, normalized: Self.normalize(
                CommandCompletionToken.unquoted(replacement.trimmingCharacters(in: .whitespacesAndNewlines)),
                locale: locale)))
        }
        guard !candidates.isEmpty else { return nil }
        self.prefix = prefix
        self.suffix = suffix
        self.candidates = candidates
        self.locale = locale
    }

    func items(in current: String, cursorUTF16: Int) -> [CommandCompletionCandidate]? {
        guard let token = CommandCompletionToken.replacement(in: current, prefix: prefix, suffix: suffix) else { return nil }
        let currentRange = NSRange(location: prefix.utf16.count, length: token.utf16.count)
        guard cursorUTF16 >= currentRange.location, cursorUTF16 <= NSMaxRange(currentRange),
              CommandCompletionToken.range(in: current, cursorUTF16: cursorUTF16) == currentRange else { return nil }
        let query = Self.normalize(CommandCompletionToken.unquoted(
            (token as NSString).substring(to: cursorUTF16 - currentRange.location)), locale: locale)
        return candidates.enumerated().compactMap { index, item -> (Int, Int, CommandCompletionCandidate)? in
            guard let score = Self.score(query, in: item.normalized) else { return nil }
            return (score, index, .init(displayText: item.candidate.displayText, detail: item.candidate.detail,
                                       replacementText: item.candidate.replacementText, replacementRange: currentRange,
                                       cursorUTF16: item.candidate.cursorUTF16))
        }.sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }.map(\.2)
    }

    private static func normalize(_ text: String, locale: Locale) -> [UInt32] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).unicodeScalars.map(\.value)
    }

    private static func score(_ query: [UInt32], in value: [UInt32]) -> Int? {
        if query.count > value.count { return nil }
        if value.starts(with: query) { return 0 }
        var next = 0
        var score = 1
        for character in query {
            while next < value.count, value[next] != character { next += 1; score += 1 }
            guard next < value.count else { return nil }
            next += 1
        }
        return score
    }
}
