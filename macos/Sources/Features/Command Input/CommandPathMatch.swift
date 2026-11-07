import Foundation

struct CommandPathProbe: Equatable, Sendable {
    enum Kind: Sendable { case header, output, localLink }
    let id: UInt64
    let kind: Kind
    let text: String
    let hoverByte: Int
    let uri: String
    let workingDirectory: String?
    var context: String = ""
}

struct CommandPathMatch: Equatable, Sendable {
    let path: CommandResolvedPath
    let start: Int
    let length: Int
    func contains(_ byte: Int) -> Bool { byte >= start && byte < start + length }
}

/// Bounded literal candidates; these strings are never evaluated by a shell.
enum CommandPathCandidates {
    struct Candidate: Equatable, Sendable {
        let token: String
        let start: Int
        let length: Int
    }

    static func around(_ text: String, byte: Int) -> [Candidate] {
        let bytes = Array(text.utf8)
        guard bytes.count <= 4_096, bytes.indices.contains(byte) else { return [] }
        var result: [Candidate] = []
        func append(_ range: Range<Int>) {
            guard result.count < 8, range.contains(byte), !range.isEmpty,
                  let token = String(bytes: bytes[range], encoding: .utf8),
                  !result.contains(where: { $0.token == token && $0.start == range.lowerBound }) else { return }
            result.append(Candidate(token: token, start: range.lowerBound, length: range.count))
        }

        // Column-oriented listings use a tab or repeated spaces between
        // entries. A single space can be part of a bare filename. Try the
        // complete column before a smaller word that happens to also exist.
        func columnSeparator(_ index: Int) -> Bool {
            let value = bytes[index]
            if [9, 10, 13].contains(value) { return true }
            guard value == 32 else { return false }
            return (index > 0 && bytes[index - 1] == 32)
                || (index + 1 < bytes.count && bytes[index + 1] == 32)
        }
        if !columnSeparator(byte) {
            var lower = byte
            var upper = byte + 1
            while lower > 0, !columnSeparator(lower - 1) { lower -= 1 }
            while upper < bytes.count, !columnSeparator(upper) { upper += 1 }
            while lower < upper, bytes[lower] == 32 { lower += 1 }
            while upper > lower, bytes[upper - 1] == 32 { upper -= 1 }
            append(lower..<upper)
        }

        // Quoted filenames can contain whitespace. Keep offsets in the original
        // UTF-8 line; decoding or trimming must not move their GPU underline.
        var quoteStart: Int?
        var quote: UInt8 = 0
        var escaped = false
        for index in bytes.indices {
            let value = bytes[index]
            if escaped { escaped = false; continue }
            if value == 92, quote != 39 { escaped = true; continue }
            if let start = quoteStart {
                if value == quote {
                    append((start + 1)..<index)
                    quoteStart = nil
                }
            } else if value == 34 || value == 39 {
                quoteStart = index
                quote = value
            }
        }
        func separator(_ index: Int) -> Bool {
            let value = bytes[index]
            if [9, 10, 13, 32].contains(value) {
                var backslashes = 0
                var previous = index
                while previous > 0, bytes[previous - 1] == 92 { backslashes += 1; previous -= 1 }
                return backslashes.isMultiple(of: 2)
            }
            return [34, 39, 60, 62, 91, 93, 123, 125, 124].contains(value)
        }
        guard !separator(byte) else { return result }
        var start = byte
        var end = byte + 1
        while start > 0, !separator(start - 1) { start -= 1 }
        while end < bytes.count, !separator(end) { end += 1 }
        append(start..<end)
        // Diagnostic output often decorates a path with punctuation or line and
        // column numbers. Always try the literal filename first.
        var trimmedEnd = end
        while trimmedEnd > start, [44, 58, 59, 41, 46].contains(bytes[trimmedEnd - 1]) { trimmedEnd -= 1 }
        var trimmedStart = start
        while trimmedStart < trimmedEnd, bytes[trimmedStart] == 40 { trimmedStart += 1 }
        append(trimmedStart..<trimmedEnd)
        var position = trimmedEnd
        for _ in 0..<2 {
            let digitsEnd = position
            while position > trimmedStart, (48...57).contains(bytes[position - 1]) { position -= 1 }
            guard position < digitsEnd, position > trimmedStart, bytes[position - 1] == 58 else { break }
            position -= 1
            append(trimmedStart..<position)
        }

        // A few surrounding words allow ordinary printed paths with spaces.
        // Stat validation rejects prose; never scan unbounded history or try
        // every substring of the line.
        var left = start
        for _ in 0..<3 {
            while left > 0, bytes[left - 1] == 32 { left -= 1 }
            while left > 0, !separator(left - 1) { left -= 1 }
            if left < start, bytes[left..<start].contains(47) { append(left..<end) }
            if left == 0 { break }
        }
        var right = end
        for _ in 0..<3 {
            while right < bytes.count, bytes[right] == 32 { right += 1 }
            while right < bytes.count, !separator(right) { right += 1 }
            if right > end, bytes[start..<right].contains(47) { append(start..<right) }
            if right == bytes.count { break }
        }
        return result
    }

    static func unescape(_ token: String) -> String? {
        var result = ""
        var escaped = false
        for character in token {
            if escaped {
                guard [" ", "\\", "\"", "'"].contains(character) else { return nil }
                result.append(character)
                escaped = false
            } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        return escaped || result == token ? nil : result
    }
}
