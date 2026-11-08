import Foundation

/// A native tracking loop can use a mode outside .common/.eventTracking. Ask
/// Core Foundation for the actual mode and deliver UI work there, on main.
/// Only the tiny scheduling state crosses threads; AppKit never does.
final class NativeTabTrackingPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.patinasystems.spooky.native-tab-tracking", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var running = false
    private var pendingModes: [String] = []
    @MainActor private var timer: DispatchSourceTimer?

    @MainActor func start(_ update: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let token = lock.withLock { running = true; return generation }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.enqueue(update, token: token) }
        timer.resume()
    }

    @MainActor func stop() {
        timer?.cancel()
        timer = nil
        lock.withLock {
            generation &+= 1
            running = false
            pendingModes.removeAll(keepingCapacity: true)
        }
    }

    private func enqueue(_ update: @escaping @MainActor @Sendable () -> Void, token: UInt64) {
        let loop = CFRunLoopGetMain()!
        let mode = (CFRunLoopCopyCurrentMode(loop) ?? .defaultMode).rawValue as String
        let scheduled = lock.withLock {
            guard running, generation == token, !pendingModes.contains(mode) else { return false }
            // At most one block per run-loop mode. A pending default-mode block
            // must not prevent progress when AppKit enters a different mode.
            pendingModes.append(mode)
            return true
        }
        guard scheduled else { return }
        CFRunLoopPerformBlock(loop, mode as CFString) { [weak self] in
            guard let self else { return }
            let current = self.lock.withLock {
                guard self.running, self.generation == token else { return false }
                self.pendingModes.removeAll { $0 == mode }
                return true
            }
            guard current else { return }
            MainActor.assumeIsolated { update() }
        }
        CFRunLoopWakeUp(loop)
    }
}
