import Foundation
import Testing
@testable import DaydayCapture

struct InputEventMailboxTests {
    @Test
    func floodCoalescesMovesButPreservesStrictOrderAndControlBoundary() async throws {
        let mailbox = InputEventMailbox(maximumDataEvents: 8)
        let recorder = SuspendingMailboxRecorder(blockFirst: true)
        mailbox.start(sessionID: 1) { event in await recorder.handle(event) }

        mailbox.offer(key(1), sessionID: 1)
        await recorder.waitUntilFirstEntered()
        for index in 0..<10_000 {
            mailbox.offer(move(index), sessionID: 1)
        }
        mailbox.offer(key(2), sessionID: 1)
        mailbox.offer(.secureInputBegan, sessionID: 1)
        mailbox.offer(key(3), sessionID: 1)

        #expect(mailbox.pendingCount(sessionID: 1) == 3)
        await recorder.releaseFirst()
        try await eventually { await recorder.markers.count == 4 }
        #expect(await recorder.markers == ["key:1", "move:9999", "key:2", "secure"])
        mailbox.stop(sessionID: 1)
    }

    @Test
    func nonDroppableFloodBecomesOneFailClosedOverflowBoundary() async throws {
        let mailbox = InputEventMailbox(maximumDataEvents: 2)
        let recorder = SuspendingMailboxRecorder(blockFirst: true)
        mailbox.start(sessionID: 7) { event in await recorder.handle(event) }

        mailbox.offer(key(1), sessionID: 7)
        await recorder.waitUntilFirstEntered()
        mailbox.offer(key(2), sessionID: 7)
        mailbox.offer(key(3), sessionID: 7)
        mailbox.offer(key(4), sessionID: 7)
        mailbox.offer(key(5), sessionID: 7)

        #expect(mailbox.pendingCount(sessionID: 7) == 3)
        await recorder.releaseFirst()
        try await eventually { await recorder.markers.count == 4 }
        #expect(await recorder.markers == ["key:1", "key:2", "key:3", "overflow"])
        mailbox.stop(sessionID: 7)
    }

    @Test
    func stopClearsPendingGenerationAndANewSessionGetsAFreshDrain() async throws {
        let mailbox = InputEventMailbox(maximumDataEvents: 4)
        let oldRecorder = SuspendingMailboxRecorder(blockFirst: true)
        mailbox.start(sessionID: 11) { event in await oldRecorder.handle(event) }
        mailbox.offer(key(1), sessionID: 11)
        await oldRecorder.waitUntilFirstEntered()
        mailbox.offer(key(2), sessionID: 11)

        mailbox.stop(sessionID: 11)
        mailbox.offer(key(3), sessionID: 11)
        await oldRecorder.releaseFirst()
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(await oldRecorder.markers == ["key:1"])

        let newRecorder = SuspendingMailboxRecorder(blockFirst: false)
        mailbox.start(sessionID: 12) { event in await newRecorder.handle(event) }
        mailbox.offer(key(4), sessionID: 12)
        try await eventually { await newRecorder.markers == ["key:4"] }
        mailbox.stop(sessionID: 12)
    }

    @Test
    func tenThousandPhysicalKeysStayLosslessWhenTheConsumerKeepsUp() async throws {
        let mailbox = InputEventMailbox(maximumDataEvents: 256)
        let counter = MailboxKeyCounter()
        mailbox.start(sessionID: 23) { events in
            await counter.record(events)
        }

        for index in 0..<10_000 {
            mailbox.offer(key(UInt16(index % 128)), sessionID: 23)
            if index.isMultiple(of: 32) { await Task.yield() }
        }

        try await eventually { await counter.value == 10_000 }
        mailbox.stop(sessionID: 23)
    }
}

private actor SuspendingMailboxRecorder {
    private(set) var markers: [String] = []
    private let blockFirst: Bool
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockFirst: Bool) {
        self.blockFirst = blockFirst
    }

    func handle(_ events: [TransientInputEvent]) async {
        markers.append(contentsOf: events.map(marker))
        guard blockFirst, markers.count == 1 else { return }
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { firstContinuation = $0 }
    }

    func waitUntilFirstEntered() async {
        guard markers.isEmpty else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func marker(_ event: TransientInputEvent) -> String {
        switch event {
        case let .keyDown(_, code, _):
            return "key:\(code)"
        case let .pointerMoved(_, point):
            return "move:\(Int(point.x))"
        case .pointerButtonDown:
            return "button"
        case .scroll:
            return "scroll"
        case .secureInputBegan:
            return "secure"
        case .authorizationLost:
            return "authorization"
        case .tapDisabled:
            return "disabled"
        case .mailboxOverflow:
            return "overflow"
        }
    }
}

private actor MailboxKeyCounter {
    private(set) var value = 0

    func record(_ events: [TransientInputEvent]) {
        value += events.reduce(into: 0) { count, event in
            if case .keyDown = event { count += 1 }
        }
    }
}

private func key(_ code: UInt16) -> TransientInputEvent {
    .keyDown(observedAt: Date(timeIntervalSince1970: 1), hardwareKeyCode: code, isAutoRepeat: false)
}

private func move(_ x: Int) -> TransientInputEvent {
    .pointerMoved(
        observedAt: Date(timeIntervalSince1970: Double(x + 1)),
        point: .init(x: Double(x), y: 0)
    )
}

private func eventually(
    attempts: Int = 200,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Condition was not met")
}
