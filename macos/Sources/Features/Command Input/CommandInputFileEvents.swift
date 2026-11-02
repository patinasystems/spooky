import Darwin
import Foundation

/// Watches atomic directory publications, not the files replaced by each write.
/// The current block needs its own watch because directory events do not recurse.
/// A bounded stream coalesces bursts while a snapshot is being read.
final class CommandInputFileEvents: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let directory: URL
    private let queue = DispatchQueue(label: "com.patinasystems.ghostty.input-events", qos: .userInitiated)
    // Everything below is confined to queue. Queued work retains no session.
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var liveBlock: String?
    private var scheduled: DispatchWorkItem?
    private let watchdog: DispatchSourceTimer

    init(directory: URL, watchdogInterval: TimeInterval = 2) {
        self.directory = directory
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        continuation = stream.continuation
        watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval,
                          leeway: .milliseconds(50))
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            CommandInputDiagnostics.record(.bridgeWatchdog)
            self.installWatches()
            self.publishSoon()
        }
        watchdog.resume()
        queue.async { [weak self] in
            self?.installWatches()
            self?.publishSoon()
        }
    }

    deinit {
        // A queued handler holds self while touching queue-confined fields;
        // deinit therefore cannot overlap a running field mutation.
        scheduled?.cancel()
        watchdog.cancel()
        for source in sources.values { source.cancel() }
        continuation.finish()
    }

    func requestRefresh() {
        queue.async { [weak self] in self?.publishSoon() }
    }

    func updateLiveBlock(_ id: String?) {
        let safeID = id.flatMap { value in
            !value.isEmpty && value.utf8.count <= 64
                && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 45 } ? value : nil
        }
        queue.async { [weak self] in
            guard let self, self.liveBlock != safeID else { return }
            self.liveBlock = safeID
            self.installWatches()
            // Read once after installing: this closes the race between the
            // state snapshot naming a block and attaching its directory watch.
            self.publishSoon()
        }
    }

    private func installWatches() {
        let blocks = directory.appendingPathComponent("blocks", isDirectory: true)
        var desired: Set<URL> = [directory, blocks]
        if let liveBlock { desired.insert(blocks.appendingPathComponent(liveBlock, isDirectory: true)) }
        for url in Array(sources.keys) where !desired.contains(url) {
            sources.removeValue(forKey: url)?.cancel()
        }
        for url in desired where sources[url] == nil {
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue } // Watchdog retries missing directories.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in
                guard let self, let source = self.sources[url] else { return }
                CommandInputDiagnostics.record(.bridgeWatchEvent)
                if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                    self.sources.removeValue(forKey: url)?.cancel()
                }
                self.installWatches()
                self.publishSoon()
            }
            sources[url] = source
            source.resume()
        }
    }

    private func publishSoon() {
        guard scheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.continuation.yield(())
        }
        scheduled = work
        queue.asyncAfter(deadline: .now() + .milliseconds(10), execute: work)
    }
}
