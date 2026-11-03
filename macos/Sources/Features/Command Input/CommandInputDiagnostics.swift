import Foundation

/// Opt-in aggregate timings. Never records commands, document text, or paths.
/// Disabled calls do not initialize the recorder or allocate measurement state.
enum CommandInputDiagnostics {
    enum Operation: String, CaseIterable, Sendable {
        case geometrySnapshot, bridgeSnapshot, hostSynchronize, headerDraw, textMeasurement
        case submissionDispatch, submissionToBoundary
    }

    enum Counter: String, CaseIterable, Sendable {
        case bridgeFileRead, bridgeFileBytes, geometryChanged, headerInvalidation
        case bridgeSnapshotRequested, bridgeWatchEvent, bridgeWatchdog, bridgeCacheHit
        case chromePublication, geometryBusy
    }

    struct Token: Sendable {
        fileprivate let operation: Operation
        fileprivate let started: UInt64
    }

    private static let enabled = ProcessInfo.processInfo.environment["GHOSTTY_NATIVE_INPUT_DIAGNOSTICS"] == "1"
    private static let recorder = Recorder()

    static func begin(_ operation: Operation) -> Token? {
        guard enabled else { return nil }
        _ = recorder
        return Token(operation: operation, started: DispatchTime.now().uptimeNanoseconds)
    }

    static func end(_ token: Token?) {
        guard let token else { return }
        recorder.add(token.operation, nanoseconds: DispatchTime.now().uptimeNanoseconds &- token.started)
    }

    static func record(_ counter: Counter, amount: Int = 1) {
        guard enabled, amount > 0 else { return }
        recorder.add(counter, amount: UInt64(amount))
    }

    /// All mutable fields are protected by lock; the timer only drains copies.
    private final class Recorder: @unchecked Sendable {
        private struct Timing {
            var count: UInt64 = 0
            var nanoseconds: UInt64 = 0
            var maximum: UInt64 = 0
        }

        private let lock = NSLock()
        private var timings: [Operation: Timing] = [:]
        private var counters: [Counter: UInt64] = [:]
        private var previous = DispatchTime.now().uptimeNanoseconds
        private var sequence: UInt64 = 0
        private let timer: DispatchSourceTimer

        init() {
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
                label: "com.patinasystems.ghostty.input-diagnostics", qos: .utility))
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.flush() }
            timer.resume()
        }

        func add(_ operation: Operation, nanoseconds: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            var timing = timings[operation] ?? Timing()
            timing.count &+= 1
            timing.nanoseconds &+= nanoseconds
            timing.maximum = max(timing.maximum, nanoseconds)
            timings[operation] = timing
        }

        func add(_ counter: Counter, amount: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            counters[counter, default: 0] &+= amount
        }

        private func flush() {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            let elapsed = now &- previous
            previous = now
            sequence &+= 1
            let sequence = self.sequence
            let timings = self.timings
            let counters = self.counters
            self.timings.removeAll(keepingCapacity: true)
            self.counters.removeAll(keepingCapacity: true)
            lock.unlock()

            let operations = Dictionary(uniqueKeysWithValues: Operation.allCases.map { operation in
                let timing = timings[operation] ?? Timing()
                return (operation.rawValue, [
                    "count": Double(timing.count),
                    "total_ms": Double(timing.nanoseconds) / 1_000_000,
                    "mean_us": timing.count > 0 ? Double(timing.nanoseconds) / Double(timing.count) / 1_000 : 0,
                    "max_us": Double(timing.maximum) / 1_000
                ])
            })
            let record: [String: Any] = [
                "kind": "native-input-performance", "schema": 1,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "sequence": sequence,
                "elapsed_s": Double(elapsed) / 1_000_000_000,
                "operations": operations,
                "counters": Dictionary(uniqueKeysWithValues: Counter.allCases.map { ($0.rawValue, counters[$0] ?? 0) })
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            data.append(0x0a)
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}
