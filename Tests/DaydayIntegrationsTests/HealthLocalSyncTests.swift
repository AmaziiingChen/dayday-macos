@testable import DaydayIntegrations
import Foundation
import Testing

@Suite("Health local sync pairing")
struct HealthLocalSyncTests {
  @Test("A generated setup code round-trips its exact local credential")
  func setupCodeRoundTrip() throws {
    let credential = try HealthPairingCredential(
      installationID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
      secret: Data(repeating: 0x5A, count: 32)
    )

    #expect(try HealthPairingCredential(setupCode: credential.setupCode) == credential)
    #expect(credential.setupCode.hasPrefix("dayday-health://pair/"))
    #expect(!credential.setupCode.contains("+"))
    #expect(!credential.setupCode.contains("="))
  }

  @Test("Malformed or short setup material is rejected before networking")
  func setupCodeRejectsInvalidMaterial() {
    #expect(throws: HealthPairingCredential.Error.invalidSecret) {
      _ = try HealthPairingCredential(setupCode: "dayday-health://pair/not-a-uuid/short")
    }
    #expect(throws: HealthPairingCredential.Error.invalidSecret) {
      _ = try HealthPairingCredential(
        installationID: UUID(), secret: Data(repeating: 0, count: 31)
      )
    }
  }

  @Test("The receiver admits only one archive transaction and releases capacity afterwards")
  func receiverBackpressureIsBounded() throws {
    let gate = HealthLocalSyncConnectionGate()
    let noCancellation: @Sendable () -> Void = {}
    let acquiredFirst = gate.acquire(cancel: noCancellation)
    let first = try #require(acquiredFirst)

    #expect(gate.acquire(cancel: noCancellation) == nil)

    gate.release(first)
    let acquiredSecond = gate.acquire(cancel: noCancellation)
    let second = try #require(acquiredSecond)
    #expect(second != first)
  }

  @Test("Stopping cancels but retains admission until the old transaction actually exits")
  func receiverStopRetainsAdmissionUntilRelease() throws {
    let gate = HealthLocalSyncConnectionGate()
    let cancellation = CancellationProbe()
    let cancellationAction: @Sendable () -> Void = { cancellation.markCancelled() }
    let acquired = gate.acquire(cancel: cancellationAction)
    _ = try #require(acquired)

    gate.cancelActive()

    #expect(cancellation.wasCancelled)
    let noCancellation: @Sendable () -> Void = {}
    #expect(gate.acquire(cancel: noCancellation) == nil)

    gate.release(try #require(acquired))
    #expect(gate.acquire(cancel: noCancellation) != nil)
  }

  @Test("A stopped or superseded listener generation cannot publish stale results")
  func listenerGenerationRejectsStaleWork() {
    let lifecycle = HealthLocalSyncLifecycle()
    let first = lifecycle.begin()
    #expect(lifecycle.isActive(first))

    lifecycle.stop()
    #expect(!lifecycle.isActive(first))

    let second = lifecycle.begin()
    #expect(lifecycle.isActive(second))
    #expect(!lifecycle.isActive(first))
  }

  @Test("Restart cannot admit a second apply until the cancelled old apply exits")
  func restartWaitsForOldApplyExit() throws {
    let lifecycle = HealthLocalSyncLifecycle()
    let gate = HealthLocalSyncConnectionGate()
    let noCancellation: @Sendable () -> Void = {}
    let oldGeneration = lifecycle.begin()
    let acquiredOldToken = gate.acquire(cancel: noCancellation)
    let oldToken = try #require(acquiredOldToken)

    lifecycle.stop()
    gate.cancelActive()
    let newGeneration = lifecycle.begin()

    #expect(!lifecycle.isActive(oldGeneration))
    #expect(lifecycle.isActive(newGeneration))
    #expect(gate.acquire(cancel: noCancellation) == nil)

    gate.release(oldToken)
    #expect(gate.acquire(cancel: noCancellation) != nil)
  }
}

private final class CancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var wasCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func markCancelled() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
