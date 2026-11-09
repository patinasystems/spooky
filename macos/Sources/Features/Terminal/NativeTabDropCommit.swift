import Foundation

/// AppKit must finish its native tab tracking before we close or rehost its
/// source window. One pending commit, cancelled when another gesture starts.
@MainActor
final class NativeTabDropCommit {
    private var generation: UInt64 = 0
    private var scheduled = false
    private var dispatchDepth = 0
    private var pending: (@MainActor @Sendable () -> Void)?

    func beginDispatch() { dispatchDepth += 1 }

    func endDispatch() {
        precondition(dispatchDepth > 0)
        dispatchDepth -= 1
        enqueueIfReady()
    }

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
        guard pending == nil else { return }
        pending = operation
        enqueueIfReady()
    }

    private func enqueueIfReady() {
        guard dispatchDepth == 0, pending != nil, !scheduled else { return }
        scheduled = true
        let token = generation
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.scheduled = false
                // A newer native event may have entered another nested loop
                // since this block was queued. Its outer dispatch will retry.
                guard self.dispatchDepth == 0, let operation = self.pending else { return }
                self.pending = nil
                operation()
            }
        }
    }

    func cancel() {
        generation &+= 1
        scheduled = false
        pending = nil
    }
}
