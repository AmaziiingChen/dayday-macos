import Foundation

/// One bounded, strictly serial delivery lane for a tap generation.
///
/// A session owns exactly one drain task. Callback threads synchronously append
/// to this mailbox and never create per-event tasks. The drain hands one bounded
/// batch to Capture, so rapid physical input produces one actor hop per batch
/// rather than one hop per CoreGraphics callback. Consecutive pending pointer
/// movements are replaced by their newest point. Non-movement overflow becomes
/// a mandatory control boundary, causing the collector to stop rather than
/// retaining an unbounded raw-event history or silently losing key/click facts.
final class InputEventMailbox: @unchecked Sendable {
    typealias Handler = @Sendable ([TransientInputEvent]) async -> Void

    private struct State {
        var sessionID: UInt64?
        var token: UUID?
        var queue: [TransientInputEvent] = []
        var waiter: CheckedContinuation<[TransientInputEvent]?, Never>?
        var boundaryAdmitted = false
    }

    private let lock = NSLock()
    private let maximumDataEvents: Int
    private var state = State()

    init(maximumDataEvents: Int = 256) {
        precondition(maximumDataEvents > 0)
        self.maximumDataEvents = maximumDataEvents
    }

    func start(sessionID: UInt64, handler: @escaping Handler) {
        let token = UUID()
        let staleWaiter = lock.withLock { () -> CheckedContinuation<[TransientInputEvent]?, Never>? in
            let staleWaiter = state.waiter
            state = State(sessionID: sessionID, token: token)
            return staleWaiter
        }
        staleWaiter?.resume(returning: nil)

        Task { [weak self] in
            await self?.drain(token: token, handler: handler)
        }
    }

    func offer(_ event: TransientInputEvent, sessionID: UInt64) {
        var directWaiter: CheckedContinuation<[TransientInputEvent]?, Never>?
        lock.withLock {
            guard state.sessionID == sessionID,
                  state.token != nil,
                  !state.boundaryAdmitted else { return }

            if event.isMailboxControlBoundary {
                state.boundaryAdmitted = true
            }

            if let waiter = state.waiter, state.queue.isEmpty {
                state.waiter = nil
                directWaiter = waiter
                return
            }

            if event.isPointerMovement {
                if state.queue.last?.isPointerMovement == true {
                    state.queue[state.queue.count - 1] = event
                } else if state.queue.count < maximumDataEvents {
                    state.queue.append(event)
                }
                return
            }

            if event.isMailboxControlBoundary || state.queue.count < maximumDataEvents {
                state.queue.append(event)
            } else {
                // The extra boundary slot makes the hard maximum
                // `maximumDataEvents + 1`; later callbacks are suppressed.
                state.queue.append(.mailboxOverflow)
                state.boundaryAdmitted = true
            }
        }
        directWaiter?.resume(returning: [event])
    }

    func stop(sessionID: UInt64) {
        let waiter = lock.withLock { () -> CheckedContinuation<[TransientInputEvent]?, Never>? in
            guard state.sessionID == sessionID else { return nil }
            let waiter = state.waiter
            state = State()
            return waiter
        }
        waiter?.resume(returning: nil)
    }

    func pendingCount(sessionID: UInt64) -> Int {
        lock.withLock {
            guard state.sessionID == sessionID else { return 0 }
            return state.queue.count
        }
    }

    private func drain(token: UUID, handler: @escaping Handler) async {
        while let events = await nextBatch(token: token) {
            await handler(events)
        }
    }

    private func nextBatch(token: UUID) async -> [TransientInputEvent]? {
        await withCheckedContinuation { continuation in
            var immediate: [TransientInputEvent]??
            lock.withLock {
                guard state.token == token else {
                    immediate = .some(nil)
                    return
                }
                if !state.queue.isEmpty {
                    immediate = .some(state.queue)
                    state.queue.removeAll(keepingCapacity: true)
                } else {
                    precondition(state.waiter == nil)
                    state.waiter = continuation
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }
}

private extension TransientInputEvent {
    var isPointerMovement: Bool {
        if case .pointerMoved = self { return true }
        return false
    }

    var isMailboxControlBoundary: Bool {
        switch self {
        case .secureInputBegan, .authorizationLost, .tapDisabled, .mailboxOverflow:
            return true
        case .keyDown, .pointerMoved, .pointerButtonDown, .scroll:
            return false
        }
    }
}
