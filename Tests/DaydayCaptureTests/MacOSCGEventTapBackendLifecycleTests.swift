import Foundation
import Testing

@testable import DaydayCapture

@Suite("macOS event tap callback lifecycle")
struct MacOSCGEventTapBackendLifecycleTests {
  @Test("a callback token becomes a safe no-op after removal")
  func lateCallbackIsDroppedAfterRemoval() {
    let registry = EventTapCallbackRegistry<() -> Void>()
    let counter = LockedCounter()
    let token = registry.insert { counter.increment() }

    registry.withValue(for: token) { callback in callback() }
    #expect(counter.value == 1)

    registry.removeValue(for: token)
    registry.withValue(for: token) { callback in callback() }

    #expect(counter.value == 1)
    #expect(!registry.contains(token))
  }

  @Test("removal waits for an in-flight callback and rejects later delivery")
  func removalSerializesWithInFlightCallback() {
    let registry = EventTapCallbackRegistry<() -> Void>()
    let callbackEntered = DispatchSemaphore(value: 0)
    let allowCallbackToReturn = DispatchSemaphore(value: 0)
    let removalFinished = DispatchSemaphore(value: 0)
    let callbackQueue = DispatchQueue(label: "dayday.tests.event-tap.callback")
    let removalQueue = DispatchQueue(label: "dayday.tests.event-tap.removal")
    let counter = LockedCounter()

    let token = registry.insert {
      callbackEntered.signal()
      _ = allowCallbackToReturn.wait(timeout: .now() + 2)
      counter.increment()
    }

    callbackQueue.async {
      registry.withValue(for: token) { callback in callback() }
    }
    #expect(callbackEntered.wait(timeout: .now() + 1) == .success)

    removalQueue.async {
      registry.removeValue(for: token)
      removalFinished.signal()
    }
    #expect(removalFinished.wait(timeout: .now() + 0.05) == .timedOut)

    allowCallbackToReturn.signal()
    #expect(removalFinished.wait(timeout: .now() + 1) == .success)
    registry.withValue(for: token) { callback in callback() }

    #expect(counter.value == 1)
  }

  @Test("tokens are not immediately reused after teardown")
  func tokensAdvanceAcrossSessions() {
    let registry = EventTapCallbackRegistry<Int>()
    let first = registry.insert(1)
    registry.removeValue(for: first)
    let second = registry.insert(2)

    #expect(first != second)
    #expect(first != 0)
    #expect(second != 0)
  }

  @Test("the dedicated tap loop remains available before the first source is installed")
  func tapThreadSurvivesInitialIdlePeriod() throws {
    let tapThread = InputEventTapThread(name: "dayday.tests.input-tap")
    let completed = DispatchSemaphore(value: 0)

    try tapThread.performAndWait { _ in
      completed.signal()
    }

    #expect(completed.wait(timeout: .now() + 1) == .success)
    tapThread.stop()
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func increment() {
    lock.withLock { storage += 1 }
  }
}
