import Foundation

/// Display and cached filtering only. Zsh still owns parsing, quoting, and the
/// exact replacement buffer; this scanner never evaluates shell input.
enum CommandCompletionToken {
    static func range(in text: String, cursorUTF16: Int) -> NSRange? {
        let units = Array(text.utf16)
        guard CommandCompletionBridge.byteOffset(in: text, cursorUTF16: cursorUTF16) != nil else { return nil }
        var start: Int?
        var quote: UInt16?
        var escaped = false
        for index in 0...units.count {
            let unit = index < units.count ? units[index] : 0
            let separator = index == units.count || (quote == nil && !escaped && isSeparator(unit))
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
        let value = result as NSString
        let prefix = original.substring(to: range.location)
        let suffix = original.substring(from: NSMaxRange(range))
        let length = value.length - (prefix as NSString).length - (suffix as NSString).length
        guard length >= 0,
              value.substring(to: range.location).utf16.elementsEqual(prefix.utf16),
              value.substring(from: range.location + length).utf16.elementsEqual(suffix.utf16) else { return nil }
        let replacementRange = NSRange(location: range.location, length: length)
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
                result.append(character)
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

/// Results may be reused only while the unchanged command prefix and suffix
/// still surround one active token. Accepting always replaces its current range.
struct CommandCompletionFilter {
    private let text: String
    private let range: NSRange
    private let candidates: [CommandCompletionCandidate]

    init?(request: CommandCompletionRequest, items: [CommandCompletionCandidate]) {
        guard let range = CommandCompletionToken.range(in: request.text, cursorUTF16: request.cursorUTF16),
              !items.isEmpty else { return nil }
        var candidates: [CommandCompletionCandidate] = []
        for item in items {
            let result = (request.text as NSString).replacingCharacters(in: item.replacementRange, with: item.replacementText)
            guard let replacement = CommandCompletionToken.replacement(in: result, original: request.text, range: range) else {
                return nil
            }
            candidates.append(.init(displayText: item.displayText, detail: item.detail, replacementText: replacement,
                                    replacementRange: range, cursorUTF16: item.cursorUTF16 ??
                                        item.replacementRange.location + item.replacementText.utf16.count))
        }
        self.text = request.text
        self.range = range
        self.candidates = candidates
    }

    func items(in current: String, cursorUTF16: Int) -> [CommandCompletionCandidate]? {
        guard let token = CommandCompletionToken.replacement(in: current, original: text, range: range) else { return nil }
        let currentRange = NSRange(location: range.location, length: token.utf16.count)
        guard cursorUTF16 >= currentRange.location, cursorUTF16 <= NSMaxRange(currentRange),
              CommandCompletionToken.range(in: current, cursorUTF16: cursorUTF16) == currentRange else { return nil }
        let query = CommandCompletionToken.unquoted((token as NSString).substring(to: cursorUTF16 - range.location))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return candidates.enumerated().compactMap { index, candidate -> (Int, Int, CommandCompletionCandidate)? in
            let label = candidate.displayText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard let score = Self.score(query, in: label) else { return nil }
            return (score, index, .init(displayText: candidate.displayText, detail: candidate.detail,
                                       replacementText: candidate.replacementText, replacementRange: currentRange,
                                       cursorUTF16: candidate.cursorUTF16))
        }.sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }.map(\.2)
    }

    private static func score(_ query: String, in value: String) -> Int? {
        if value.hasPrefix(query) { return 0 }
        var remaining = value[...]
        var score = 1
        for character in query {
            guard let index = remaining.firstIndex(of: character) else { return nil }
            score += remaining.distance(from: remaining.startIndex, to: index)
            remaining = remaining[remaining.index(after: index)...]
        }
        return score
    }
}
