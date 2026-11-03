import Foundation
import Dispatch

@main
struct CompletionBenchmark {
    static func main() throws {
        let iterations = Int(CommandLine.arguments.dropFirst().first ?? "2000") ?? 2000
        let request = CommandCompletionRequest(id: UUID(), revision: 1, text: "cat docs/p --quiet", cursorUTF16: 10)
        let candidates = (0..<200).map { index in
            let option = "docs/Project-\(index)-Café-Notes.md"
            return CommandCompletionCandidate(displayText: option, detail: "",
                replacementText: "cat " + option + " --quiet",
                replacementRange: NSRange(location: 0, length: request.text.utf16.count))
        }
        let index = CommandCompletionFilter(request: request, items: candidates)!
        let legacy = LegacyCommandCompletionFilter(request: request, items: candidates)!
        let queries = ["docs/p", "docs/pr", "docs/pj", "docs/cf", "docs/nt", "docs/9999", "docs/"]
        let drafts = queries.map { "cat " + $0 + " --quiet" }
        let cursors = queries.map { 4 + $0.utf16.count }
        var checksum = 0
        for iteration in 0..<200 {
            let query = iteration % queries.count
            checksum += index.items(in: drafts[query], cursorUTF16: cursors[query])!.count
            checksum += legacy.items(in: drafts[query], cursorUTF16: cursors[query])!.count
        }
        var currentNS: [Double] = []
        var legacyNS: [Double] = []
        for iteration in 0..<iterations {
            let query = iteration % queries.count
            // Alternate order to reduce directional warm-cache bias.
            if iteration.isMultiple(of: 2) {
                measure(into: &currentNS) { checksum += index.items(in: drafts[query], cursorUTF16: cursors[query])!.count }
                measure(into: &legacyNS) { checksum += legacy.items(in: drafts[query], cursorUTF16: cursors[query])!.count }
            } else {
                measure(into: &legacyNS) { checksum += legacy.items(in: drafts[query], cursorUTF16: cursors[query])!.count }
                measure(into: &currentNS) { checksum += index.items(in: drafts[query], cursorUTF16: cursors[query])!.count }
            }
        }
        let result: [String: Any] = [
            "candidates": candidates.count, "iterations": iterations, "warmup": 200,
            "indexed_query_us": summary(currentNS), "prior_query_us": summary(legacyNS),
            "checksum": checksum,
            "scope": "Optimized Swift helper only; 200 Unicode path candidates, seven repeated prefix/fuzzy/no-match queries. AppKit, shell, and IPC excluded."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func measure(into samples: inout [Double], operation: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
    }

    static func summary(_ samples: [Double]) -> [String: Double] {
        let sorted = samples.sorted()
        return ["median": sorted[sorted.count / 2] / 1000,
                "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] / 1000,
                "max": sorted.last! / 1000]
    }
}
