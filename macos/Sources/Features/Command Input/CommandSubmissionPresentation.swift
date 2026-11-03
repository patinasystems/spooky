import Foundation

/// Visual acknowledgement is independent of keyboard ownership. A parsed C
/// yields input immediately; an old native echo lasts only until its frame or
/// the bounded recovery deadline. No timer or terminal state lives here.
struct CommandSubmissionPresentation {
    private(set) var blockID: String?
    private var deadline: ContinuousClock.Instant?
    private var presentedID: String?
    private var presentedSerial: UInt64 = 0

    mutating func begin(blockID: String, now: ContinuousClock.Instant) -> Bool {
        guard blockID != presentedID else { cancel(); return false }
        self.blockID = blockID
        deadline = now + .milliseconds(100)
        return true
    }

    /// Empty IDs may belong to an older pre-C frame. Only a verified command
    /// frame can acknowledge presentation; lifecycle cancellation is separate.
    mutating func presented(blockID: String?, serial: UInt64) -> Bool {
        guard let blockID, !blockID.isEmpty, serial > presentedSerial else { return false }
        presentedSerial = serial
        presentedID = blockID
        guard blockID == self.blockID else { return false }
        return cancel()
    }

    mutating func expire(now: ContinuousClock.Instant) -> Bool {
        guard let deadline, now >= deadline else { return false }
        return cancel()
    }

    func nextCheckDelay(maximum: Duration, now: ContinuousClock.Instant) -> Duration {
        guard let deadline else { return maximum }
        return max(.zero, min(maximum, now.duration(to: deadline)))
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let hadEcho = blockID != nil
        blockID = nil
        deadline = nil
        return hadEcho
    }
}
