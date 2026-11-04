import Foundation
import Testing
@testable import Ghostty

struct CommandCompletionContextTests {
    @Test func optionQueriesKeepTheirDashPrefixAndPrecedingArguments() throws {
        for draft in ["git log --auth", "ls -al", "tool --format=j"] {
            #expect(CommandCompletionQuery.broadened(text: draft, cursorUTF16: draft.utf16.count) == nil)
        }
        for (draft, expected) in [("tool build --format j", "tool build --format ")] {
            let query = try #require(CommandCompletionQuery.broadened(text: draft, cursorUTF16: draft.utf16.count))
            #expect(query.text == expected)
            #expect(query.cursorUTF16 == expected.utf16.count)
        }
        #expect(CommandCompletionQuery.broadened(text: "tool --format=j", cursorUTF16: 15) == nil)
    }

    @Test func changingFromFilesToFlagsOrIntoADirectoryInvalidatesTheOldUniverse() throws {
        let original = request("tool ", cursor: 5)
        let filter = try #require(CommandCompletionFilter(request: original, items: [
            candidate("tool report-file", option: "report-file", request: original, cursor: 16)
        ]))
        #expect(filter.items(in: "tool rep", cursorUTF16: 8)?.count == 1)
        #expect(filter.items(in: "tool -", cursorUTF16: 6) == nil)
        #expect(filter.items(in: "tool report/", cursorUTF16: 12) == nil)
        let flag = request("tool --format", cursor: 13)
        let flags = try #require(CommandCompletionFilter(request: flag, items: [
            candidate("tool --format=", option: "--format=", request: flag, cursor: 14)
        ]))
        #expect(flags.items(in: "tool --format=", cursorUTF16: 14) == nil)
    }

    @Test func argumentQueryPreservesTheCommandAndTrailingArguments() throws {
        let draft = "git ckt --quiet"
        let query = try #require(CommandCompletionQuery.broadened(text: draft, cursorUTF16: 7))
        #expect(query.text == "git  --quiet")
        #expect(query.cursorUTF16 == 4)
        let request = request(draft, cursor: 7)
        let filter = try #require(CommandCompletionFilter(request: request, items: [
            candidate("git checkout --quiet", option: "checkout", request: request, cursor: 12),
            candidate("git cherry-pick --quiet", option: "cherry-pick", request: request, cursor: 15)
        ]))
        let matches = try #require(filter.items(in: draft, cursorUTF16: 7))
        #expect(matches.map(\.displayText) == ["checkout"])
        #expect(matches.first?.replacementRange == NSRange(location: 4, length: 3))
        #expect(matches.first?.replacementText == "checkout")
        #expect(matches.first?.cursorUTF16 == 12)
    }

    @Test func commandQueriesKeepTheirFirstTypedCharacterAndStatementContext() throws {
        let simple = try #require(CommandCompletionQuery.broadened(text: "gch", cursorUTF16: 3))
        #expect(simple.text == "g")
        #expect(simple.cursorUTF16 == 1)
        let compound = "echo 👋; /usr/bin/pyth --version"
        let caret = (compound as NSString).range(of: " --version").location
        let query = try #require(CommandCompletionQuery.broadened(text: compound, cursorUTF16: caret))
        #expect(query.text == "echo 👋; /usr/bin/p --version")
        #expect(query.cursorUTF16 == "echo 👋; /usr/bin/p".utf16.count)
        #expect(CommandCompletionQuery.broadened(text: "", cursorUTF16: 0) == nil)
    }

    @Test func pathQueriesKeepQuotedDirectoriesAndUnicodeMiddleCaret() throws {
        let prefix = "echo 👋\ncat "
        let draft = prefix + "\"café folder/ntes.txt\" --quiet"
        let cursor = prefix.utf16.count + "\"café folder/nte".utf16.count
        let query = try #require(CommandCompletionQuery.broadened(text: draft, cursorUTF16: cursor))
        #expect(query.text == prefix + "\"café folder/\" --quiet")
        #expect(query.cursorUTF16 == prefix.utf16.count + "\"café folder/".utf16.count)

        let request = request(draft, cursor: cursor)
        let completed = "\"café folder/notes.txt\""
        let filter = try #require(CommandCompletionFilter(request: request, items: [
            candidate(prefix + completed + " --quiet", option: "café folder/notes.txt", request: request,
                      cursor: prefix.utf16.count + completed.utf16.count)
        ]))
        let matches = try #require(filter.items(in: draft, cursorUTF16: cursor))
        #expect(matches.count == 1)
        #expect(matches.first?.replacementRange == NSRange(location: prefix.utf16.count,
                                                          length: "\"café folder/ntes.txt\"".utf16.count))
        #expect(matches.first?.replacementText == completed)
        #expect(matches.first?.cursorUTF16 == prefix.utf16.count + completed.utf16.count)
    }

    @Test func querySupportsEscapedSpacesAndOpenQuotesWithoutChangingTheSuffix() throws {
        let escaped = try #require(CommandCompletionQuery.broadened(
            text: "cat docs\\ folder/na --quiet", cursorUTF16: "cat docs\\ folder/na".utf16.count))
        #expect(escaped.text == "cat docs\\ folder/ --quiet")
        let single = try #require(CommandCompletionQuery.broadened(text: "cat 'docs/na'", cursorUTF16: 12))
        #expect(single.text == "cat 'docs/'")
        #expect(single.cursorUTF16 == 10)
        let open = try #require(CommandCompletionQuery.broadened(text: "cat \"docs/na", cursorUTF16: 12))
        #expect(open.text == "cat \"docs/")
        #expect(open.cursorUTF16 == 10)
    }

    @Test func uncertainShellSyntaxKeepsTheExactShellQuery() {
        for draft in ["cat $(pwd)/na", "cat $ROOT/na", "cat docs/*na", "cat docs/\"na\"",
                      "sudo gi", "A=b git ch", "echo `pwd`; git ch", "cat > fi", "cat docs\\"] {
            #expect(CommandCompletionQuery.broadened(text: draft, cursorUTF16: draft.utf16.count) == nil)
        }
        #expect(CommandCompletionQuery.broadened(text: "cat docs/name", cursorUTF16: 6) == nil)
        #expect(CommandCompletionQuery.broadened(text: "cat 👋", cursorUTF16: 5) == nil)
    }

    @Test func matchingUsesTheFullCandidateEvenWhenItsDisplayPreviewIsTruncated() throws {
        let option = String(repeating: "a", count: 260) + "needle"
        let request = request("cat ", cursor: 4)
        let filter = try #require(CommandCompletionFilter(request: request, items: [
            candidate("cat " + option, option: String(option.prefix(240)), request: request)
        ]))
        let current = "cat " + String(repeating: "a", count: 250) + "ndle"
        let matches = try #require(filter.items(in: current, cursorUTF16: current.utf16.count))
        #expect(matches.count == 1)
        #expect(matches.first?.replacementText == option)
        #expect(matches.first?.replacementRange.length == 254)
    }

    @Test func indexedMatchingFoldsUnicodeOnceAndKeepsStableOrdering() throws {
        let request = request("cat ca", cursor: 6)
        let filter = try #require(CommandCompletionFilter(request: request, items: [
            candidate("cat café", option: "café", request: request),
            candidate("cat CATALOG", option: "CATALOG", request: request),
            candidate("cat cabin", option: "cabin", request: request)
        ]))
        #expect(filter.items(in: "cat CA", cursorUTF16: 6)?.map(\.displayText) == ["café", "CATALOG", "cabin"])
        #expect(filter.items(in: "cat cfe", cursorUTF16: 7)?.map(\.displayText) == ["café"])
        #expect(filter.items(in: "cat clg", cursorUTF16: 7)?.map(\.displayText) == ["CATALOG"])
        #expect(filter.items(in: "echo ca", cursorUTF16: 7) == nil)
        #expect(filter.items(in: "cat ca;", cursorUTF16: 7) == nil)
    }

    @Test func doubleQuotedLiteralBackslashesStayInDisplayAndMatching() {
        #expect(CommandCompletionToken.unquoted("\"a\\q\"") == "a\\q")
        #expect(CommandCompletionToken.unquoted("\"a\\\"q\"") == "a\"q")
    }

    @Test func mixedCandidatesDiscardSurroundingRewritesAndKeepTheActiveToken() throws {
        let prefix = "echo café\ngit "
        let draft = prefix + "ch --quiet"
        let request = request(draft, cursor: prefix.utf16.count + 2)
        let correct = prefix + "checkout --quiet"
        let filter = try #require(CommandCompletionFilter(request: request, items: [
            candidate("echo changed\ngit cherry-pick --quiet", option: "cherry-pick", request: request),
            candidate(correct, option: "checkout", request: request, cursor: prefix.utf16.count + 8),
            candidate(prefix + "cherry-pick --force", option: "cherry-pick", request: request)
        ]))
        let matches = try #require(filter.items(in: draft, cursorUTF16: request.cursorUTF16))
        #expect(matches.map(\.displayText) == ["checkout"])
        let match = try #require(matches.first)
        #expect(match.replacementRange == NSRange(location: prefix.utf16.count, length: 2))
        #expect(match.replacementText == "checkout")
        #expect((draft as NSString).replacingCharacters(in: match.replacementRange, with: match.replacementText) == correct)
    }

    @Test func exclusivelySurroundingRewritesCannotBecomeSelectableCompletions() {
        let request = request("git ch --help", cursor: 6)
        let filter = CommandCompletionFilter(request: request, items: [
            candidate("git checkout --other", option: "checkout", request: request),
            candidate("echo changed; git checkout --help", option: "checkout", request: request),
            candidate("git checkout", option: "checkout", request: request)
        ])
        #expect(filter == nil)
    }

    private func request(_ text: String, cursor: Int) -> CommandCompletionRequest {
        .init(id: UUID(), revision: 1, text: text, cursorUTF16: cursor)
    }

    private func candidate(_ result: String, option: String, request: CommandCompletionRequest,
                           cursor: Int? = nil) -> CommandCompletionCandidate {
        .init(displayText: option, detail: "", replacementText: result,
              replacementRange: NSRange(location: 0, length: request.text.utf16.count), cursorUTF16: cursor)
    }
}
