import AppKit
import CoreFoundation

/// Passive, opt-in AppKit milestones. None of these is a compositor commit or
/// presented-pixel timestamp; the independent window recorder remains that endpoint.
@MainActor
final class CommandEditorTrace: NSObject {
    struct Revision: Equatable {
        let inputID: UInt64
        let revision: UInt64
    }

    struct Draw {
        let revisions: [Revision]
        let metrics: [String: Double]
    }

    struct State {
        private(set) var pending: [Revision] = []
        private(set) var latestRevision: UInt64 = 0
        private var drawnRevision: UInt64 = 0
        private var waking: [Revision] = []
        private(set) var deadline: TimeInterval = 0
        static let capacity = 32

        mutating func edit(inputID: UInt64, now: TimeInterval) {
            expire(now: now)
            latestRevision &+= 1
            pending.removeAll { $0.inputID == inputID }
            if pending.count == Self.capacity { pending.removeFirst() }
            pending.append(Revision(inputID: inputID, revision: latestRevision))
            deadline = now + 0.5
        }

        mutating func drew(through revision: UInt64) { drawnRevision = max(drawnRevision, revision) }

        mutating func beforeWaiting() -> [Revision] {
            let snapshot = pending
            waking = pending.filter { $0.revision <= drawnRevision }
            pending.removeAll { $0.revision <= drawnRevision }
            return snapshot
        }

        mutating func afterWaiting() -> [Revision] {
            let snapshot = waking + pending
            waking.removeAll(keepingCapacity: true)
            return snapshot
        }

        mutating func expire(now: TimeInterval) {
            if now > deadline { reset() }
        }

        mutating func reset() {
            pending.removeAll(keepingCapacity: true)
            waking.removeAll(keepingCapacity: true)
            drawnRevision = 0
            deadline = 0
        }
    }

    private weak var window: NSWindow?
    private var observer: CFRunLoopObserver?
    private var state = State()
    private var lastDrawn: [Revision] = []

    init(window: NSWindow) {
        self.window = window
        super.init()
        let activities = CFRunLoopActivity.beforeSources.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.afterWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated),
                                               name: NSWindow.didUpdateNotification, object: window)
    }

    deinit {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        NotificationCenter.default.removeObserver(self)
    }

    func edit(inputID: UInt64?) {
        guard let inputID else { return }
        state.edit(inputID: inputID, now: ProcessInfo.processInfo.systemUptime)
        mark(.editorEdit, revisions: state.pending.suffix(1))
    }

    func reset() { state.reset(); lastDrawn.removeAll(keepingCapacity: true) }

    func begin(_ stage: CommandInputDiagnostics.Stage) -> [Revision] {
        expire()
        let revisions = state.pending
        mark(stage, revisions: revisions)
        return revisions
    }

    func end(_ stage: CommandInputDiagnostics.Stage, revisions: [Revision]) {
        mark(stage, revisions: revisions)
    }

    func beginDraw(_ dirtyRect: NSRect, in view: NSView) -> Draw? {
        expire()
        guard !state.pending.isEmpty else { return nil }
        let draw = Draw(revisions: state.pending, metrics: Self.drawMetrics(dirtyRect, in: view))
        mark(.editorDrawBegin, revisions: draw.revisions, metrics: draw.metrics)
        return draw
    }

    func endDraw(_ draw: Draw?) {
        guard let draw else { return }
        mark(.editorDrawEnd, revisions: draw.revisions, metrics: draw.metrics)
        if let latest = draw.revisions.last {
            state.drew(through: latest.revision)
            lastDrawn = draw.revisions
        }
    }

    /// Local rectangles use the view's bounds coordinates. Window rectangles
    /// use logical points from the full window's top-left, before backing scale.
    /// These are draw bounds, not proof that every enclosed glyph was painted.
    static func drawMetrics(_ dirtyRect: NSRect, in view: NSView) -> [String: Double] {
        var metrics: [String: Double] = [
            "view_flipped": view.isFlipped ? 1 : 0,
            "backing_scale": Double(view.window?.backingScaleFactor ?? 1),
            "window_height": Double(view.window?.frame.height ?? 0)
        ]
        func append(_ rect: NSRect, prefix: String) {
            metrics["\(prefix)_x"] = Double(rect.origin.x)
            metrics["\(prefix)_y"] = Double(rect.origin.y)
            metrics["\(prefix)_width"] = Double(rect.width)
            metrics["\(prefix)_height"] = Double(rect.height)
        }
        append(dirtyRect, prefix: "dirty")
        append(view.visibleRect, prefix: "visible")
        append(view.bounds, prefix: "bounds")
        if let window = view.window {
            for (prefix, rect) in [("dirty_window", dirtyRect), ("visible_window", view.visibleRect)] {
                var converted = view.convert(rect, to: nil)
                converted.origin.y = window.frame.height - converted.maxY
                append(converted, prefix: prefix)
            }
        }
        return metrics
    }

    private func expire() {
        let now = ProcessInfo.processInfo.systemUptime
        if now > state.deadline { lastDrawn.removeAll(keepingCapacity: true) }
        state.expire(now: now)
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        expire()
        switch activity {
        case .beforeSources: mark(.mainRunLoopBeforeSources, revisions: state.pending)
        case .beforeWaiting: mark(.mainRunLoopBeforeWaiting, revisions: state.beforeWaiting())
        case .afterWaiting: mark(.mainRunLoopAfterWaiting, revisions: state.afterWaiting())
        default: break
        }
    }

    @objc private func windowUpdated() {
        expire()
        mark(.editorWindowDidUpdate, revisions: lastDrawn.isEmpty ? state.pending : lastDrawn)
        lastDrawn.removeAll(keepingCapacity: true)
    }

    private func mark<C: Collection>(
        _ stage: CommandInputDiagnostics.Stage,
        revisions: C,
        metrics: [String: Double] = [:]
    ) where C.Element == Revision {
        guard !revisions.isEmpty else { return }
        let number = Double(window?.windowNumber ?? -1)
        for revision in revisions {
            var values = metrics
            values["editor_revision"] = Double(revision.revision)
            values["latest_revision"] = Double(state.latestRevision)
            values["coalesced_edits"] = Double(revisions.count)
            values["window_number"] = number
            CommandInputDiagnostics.mark(stage, id: revision.inputID, metrics: values)
        }
    }
}
