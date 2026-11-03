import Foundation

/// Opt-in aggregate timings. Never records commands, document text, or paths.
/// Disabled calls do not initialize the recorder or allocate measurement state.
enum CommandInputDiagnostics {
    enum Operation: String, CaseIterable, Sendable {
        case geometrySnapshot, bridgeSnapshot, hostSynchronize, headerDraw, textMeasurement
        case submissionDispatch, submissionToBoundary, submissionEchoConstruction, submissionEchoCopy
        case nativeKeyDown, completionDidEdit, completionResponse, completionFilter
        case completionConstruction, completionShow, completionMeasureWidth, completionPosition, completionSelection
        case overlayLayout, inlineSuggestionLayout
    }

    enum Counter: String, CaseIterable, Sendable {
        case bridgeFileRead, bridgeFileBytes, geometryChanged, headerInvalidation
        case bridgeSnapshotRequested, bridgeWatchEvent, bridgeWatchdog, bridgeCacheHit
        case chromePublication, geometryBusy
        case completionReload, completionRowsConfigured, completionWidthMeasuredRows
        case completionPopupResize, completionPopupMove, overlayChromeUpdate, diagnosticEventsDropped
    }

    /// CPU/application milestones, never evidence that pixels reached a display.
    enum Stage: String, Sendable {
        case inputReceived, inputHandled, textDidChange
        case completionRequested, completionResponseReceived, completionPresentationUpdated
        case submissionBegin, submissionResizeReady, submissionRequestPublished
        case submissionTriggerQueued, submissionReceiptObserved
        case submissionCoreBoundaryObserved, submissionHandoffReleased, hostLayoutApplied, hostLayout
        case boundaryNotified
    }

    enum InputKind: String, Sendable { case keyboard, scroll }

    struct InputToken {
        fileprivate let id: UInt64
        fileprivate let previousID: UInt64?
    }

    /// Scoped to the synchronous AppKit event handler. Async work captures the
    /// ID explicitly; it must not attribute a later result to a different event.
    @MainActor private(set) static var currentInputID: UInt64?

    @MainActor static func beginInput(timestamp: TimeInterval, kind: InputKind = .keyboard) -> InputToken? {
        guard enabled else { return nil }
        let id = recorder.beginInput(timestamp: timestamp, kind: kind)
        let token = InputToken(id: id, previousID: currentInputID)
        currentInputID = id
        return token
    }

    @MainActor static func endInput(_ token: InputToken?) {
        guard let token else { return }
        mark(.inputHandled, id: token.id)
        currentInputID = token.previousID
    }

    /// Callers should guard isEnabled before constructing a metrics dictionary.
    /// Geometry snapshots may have no input ID when layout runs asynchronously.
    static func mark(_ stage: Stage, id: UInt64?, metrics: [String: Double]? = nil) {
        guard enabled, id != nil || metrics != nil else { return }
        recorder.mark(stage, id: id, metrics: metrics)
    }

    struct Token: Sendable {
        fileprivate let operation: Operation
        fileprivate let started: UInt64
    }

    static let isEnabled: Bool = {
        let setting = ProcessInfo.processInfo.environment["GHOSTTY_NATIVE_INPUT_DIAGNOSTICS"]
        let bundleDefault = Bundle.main.object(forInfoDictionaryKey: "SpookyPerformanceDiagnostics") as? Bool ?? false
        return setting == "1" || (setting != "0" && bundleDefault)
    }()
    private static var enabled: Bool { isEnabled }
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

        private struct Event {
            let id: UInt64?
            let stage: Stage
            let uptime: TimeInterval
            let sourceTimestamp: TimeInterval?
            var wallTime: TimeInterval?
            var wallAnchorUptime: TimeInterval?
            var wallAnchorSpan: TimeInterval?
            var inputKind: InputKind?
            var metrics: [String: Double]?
        }

        private let lock = NSLock()
        private var timings: [Operation: Timing] = [:]
        private var counters: [Counter: UInt64] = [:]
        private var events: [Event] = []
        private var nextInputID: UInt64 = 0
        private static let maximumEvents = 4_096
        private var previous = DispatchTime.now().uptimeNanoseconds
        private var sequence: UInt64 = 0
        private let timer: DispatchSourceTimer
        private let outputPath: String?
        private var output: FileHandle?
        private var outputPrepared = false

        init() {
            outputPath = ProcessInfo.processInfo.environment["GHOSTTY_NATIVE_INPUT_DIAGNOSTICS_PATH"]
                ?? Bundle.main.object(forInfoDictionaryKey: "SpookyPerformanceDiagnosticsPath") as? String
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

        func beginInput(timestamp: TimeInterval, kind: InputKind) -> UInt64 {
            let now = ProcessInfo.processInfo.systemUptime
            let wall = Date.timeIntervalSinceReferenceDate + Date.timeIntervalBetween1970AndReferenceDate
            let afterWall = ProcessInfo.processInfo.systemUptime
            lock.lock()
            defer { lock.unlock() }
            nextInputID &+= 1
            appendEvent(Event(id: nextInputID, stage: .inputReceived, uptime: now,
                              sourceTimestamp: timestamp > 0 && timestamp.isFinite ? timestamp : nil,
                              wallTime: wall, wallAnchorUptime: (now + afterWall) / 2,
                              wallAnchorSpan: afterWall - now, inputKind: kind))
            return nextInputID
        }

        func mark(_ stage: Stage, id: UInt64?, metrics: [String: Double]?) {
            let now = ProcessInfo.processInfo.systemUptime
            let values = metrics.map { source -> [String: Double] in
                var bounded: [String: Double] = [:]
                for (key, value) in source where value.isFinite {
                    bounded[key] = value
                    if bounded.count == 32 { break }
                }
                return bounded
            }
            lock.lock()
            defer { lock.unlock() }
            appendEvent(Event(id: id, stage: stage, uptime: now, sourceTimestamp: nil, metrics: values))
        }

        /// Called only with lock held. A noisy session cannot grow log memory.
        private func appendEvent(_ event: Event) {
            guard events.count < Self.maximumEvents else {
                counters[.diagnosticEventsDropped, default: 0] &+= 1
                return
            }
            events.append(event)
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
            let events = self.events
            self.timings.removeAll(keepingCapacity: true)
            self.counters.removeAll(keepingCapacity: true)
            self.events.removeAll(keepingCapacity: true)
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
                "kind": "native-input-performance", "schema": 2,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "sequence": sequence,
                "elapsed_s": Double(elapsed) / 1_000_000_000,
                "operations": operations,
                "counters": Dictionary(uniqueKeysWithValues: Counter.allCases.map { ($0.rawValue, counters[$0] ?? 0) }),
                "events": events.map { event -> [String: Any] in
                    var value: [String: Any] = ["stage": event.stage.rawValue, "uptime_s": event.uptime]
                    if let id = event.id { value["id"] = id }
                    if let timestamp = event.sourceTimestamp { value["event_uptime_s"] = timestamp }
                    if let wallTime = event.wallTime { value["wall_time_s"] = wallTime }
                    if let anchor = event.wallAnchorUptime { value["wall_anchor_uptime_s"] = anchor }
                    if let span = event.wallAnchorSpan { value["wall_anchor_span_s"] = span }
                    if let kind = event.inputKind { value["input_kind"] = kind.rawValue }
                    if let metrics = event.metrics { value["metrics"] = metrics }
                    return value
                },
                "event_scope": "Application CPU milestones; not display presentation times"
            ]
            guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            data.append(0x0a)
            write(data)
        }

        /// Only the utility timer calls this method; enabling measurement never
        /// opens a log or writes bytes on the UI or cooperative actor executor.
        private func write(_ data: Data) {
            if !outputPrepared {
                outputPrepared = true
                if let outputPath, outputPath.hasPrefix("/") {
                    if !FileManager.default.fileExists(atPath: outputPath) {
                        _ = FileManager.default.createFile(atPath: outputPath, contents: nil,
                                                           attributes: [.posixPermissions: 0o600])
                    }
                    output = try? FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
                    _ = try? output?.seekToEnd()
                }
            }
            try? (output ?? FileHandle.standardError).write(contentsOf: data)
        }
    }
}
