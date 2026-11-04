import Foundation
import Testing
@testable import Ghostty

struct CommandInputFileEventsTests {
    @Test func responseWatchIgnoresNestedBlockDataButObservesAtomicResponsePublication() async throws {
        let fixture = try Fixture()
        let directory = fixture.directory
        let block = directory.appendingPathComponent("blocks/1-1", isDirectory: true)
        try FileManager.default.createDirectory(at: block, withIntermediateDirectories: true)
        let watcher = CommandInputFileEvents(directory: directory, scope: .response, watchdogInterval: 60)
        defer { withExtendedLifetime(watcher) {} }
        let counter = EventCounter()
        let task = Task { for await _ in watcher.events { await counter.increment() } }
        defer { task.cancel() }
        watcher.updateLiveBlock("1-1")
        try await counter.wait(for: 1)
        try await Task.sleep(for: .milliseconds(20))
        let initial = await counter.count
        try Data("done".utf8).write(to: block.appendingPathComponent("status"), options: .atomic)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await counter.count == initial)
        try Data("ready".utf8).write(to: directory.appendingPathComponent(UUID().uuidString), options: .atomic)
        try await counter.wait(for: initial + 1)
    }

    @Test func observesAtomicStateAndLaterReceiptReplacement() async throws {
        let fixture = try Fixture()
        let watcher = CommandInputFileEvents(directory: fixture.directory, watchdogInterval: 60)
        defer { withExtendedLifetime(watcher) {} }
        let counter = EventCounter()
        let consumer = Task { for await _ in watcher.events { await counter.increment() } }
        defer { consumer.cancel() }
        try await counter.wait(for: 1)
        var previous = await counter.count
        try Data("ready\t1-1\tstart\t1-1\n".utf8).write(
            to: fixture.directory.appendingPathComponent("state"), options: .atomic)
        try await counter.wait(for: previous + 1)
        previous = await counter.count
        try Data("accepted\tlate-receipt\n".utf8).write(
            to: fixture.directory.appendingPathComponent("receipt"), options: .atomic)
        try await counter.wait(for: previous + 1)
    }

    @Test func observesCurrentBlockMetadataWithoutChangingRootState() async throws {
        let fixture = try Fixture()
        let block = fixture.directory.appendingPathComponent("blocks/1-1")
        try FileManager.default.createDirectory(at: block, withIntermediateDirectories: true)
        let state = fixture.directory.appendingPathComponent("state")
        try Data("running\t1-1\tstart\t1-1\n".utf8).write(to: state)
        let watcher = CommandInputFileEvents(directory: fixture.directory, watchdogInterval: 60)
        defer { withExtendedLifetime(watcher) {} }
        watcher.updateLiveBlock("1-1")
        let counter = EventCounter()
        let consumer = Task { for await _ in watcher.events { await counter.increment() } }
        defer { consumer.cancel() }
        try await counter.wait(for: 1)
        let previous = await counter.count
        try Data("running".utf8).write(to: block.appendingPathComponent("status"), options: .atomic)
        try await counter.wait(for: previous + 1)
        #expect(try String(contentsOf: state, encoding: .utf8) == "running\t1-1\tstart\t1-1\n")
    }

    @Test func watchdogPublishesWithoutFilesystemChanges() async throws {
        let fixture = try Fixture()
        let watcher = CommandInputFileEvents(directory: fixture.directory, watchdogInterval: 0.05)
        defer { withExtendedLifetime(watcher) {} }
        let counter = EventCounter()
        let consumer = Task { for await _ in watcher.events { await counter.increment() } }
        defer { consumer.cancel() }
        try await counter.wait(for: 3)
    }

    @Test func explicitDeadlineRefreshDoesNotWaitForWatchdog() async throws {
        let fixture = try Fixture()
        let watcher = CommandInputFileEvents(directory: fixture.directory, watchdogInterval: 60)
        defer { withExtendedLifetime(watcher) {} }
        let counter = EventCounter()
        let consumer = Task { for await _ in watcher.events { await counter.increment() } }
        defer { consumer.cancel() }
        try await counter.wait(for: 1)
        let previous = await counter.count
        watcher.requestRefresh()
        try await counter.wait(for: previous + 1)
    }

    @Test func parserBoundarySupersedesLongFilesystemCoalescingDelay() async throws {
        let fixture = try Fixture()
        let watcher = CommandInputFileEvents(directory: fixture.directory, watchdogInterval: 60,
                                             coalescingInterval: 60)
        defer { withExtendedLifetime(watcher) {} }
        let counter = EventCounter()
        let consumer = Task { for await _ in watcher.events { await counter.increment() } }
        defer { consumer.cancel() }
        // Initial observation and this request would normally wait 60 seconds.
        // The parser signal must publish through the same serialized consumer.
        watcher.requestRefresh()
        watcher.requestRefresh(immediate: true)
        try await counter.wait(for: 1)
        watcher.requestRefresh()
        watcher.requestRefresh(immediate: true)
        try await counter.wait(for: 2)
    }

    private final class Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private actor EventCounter {
        var count = 0
        func increment() { count += 1 }

        func wait(for target: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while count < target {
                if ContinuousClock.now > deadline { throw WaitError.timeout }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private enum WaitError: Error { case timeout }
}
