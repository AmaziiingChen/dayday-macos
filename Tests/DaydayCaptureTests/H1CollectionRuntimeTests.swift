import DaydayCore
import Foundation
import Testing

@testable import DaydayCapture

@MainActor
@Suite("H1 application collection runtime")
struct H1CollectionRuntimeTests {
  private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
  private let applicationID = ApplicationIdentifier(
    rawValue: UUID(uuidString: "75D2B74C-9878-4A20-AE38-0D41179B3ABF")!
  )

  @Test("durable running boundary precedes allowed application context and revision signals")
  func allowedContextIsAtomicAndSignalsAfterCommit() async throws {
    let fixture = try makeFixture(context: rawContext(title: "Roadmap"))
    var revisions = fixture.runtime.historyRevisionUpdates().makeAsyncIterator()

    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }

    let stateWrites = await fixture.repository.stateWrites
    let applicationWrites = await fixture.repository.applicationWrites
    #expect(stateWrites.first?.record.state.runtime == .running)
    #expect(applicationWrites.first?.record.applicationIdentifier == applicationID)
    #expect(applicationWrites.first?.record.windowTitleSnapshot == "Roadmap")
    #expect(fixture.runtime.snapshot.status == .running)
    #expect(fixture.runtime.snapshot.historyRevision == 2)
    #expect(await revisions.next() == 2)
  }

  @Test("unchanged health refresh keeps the admitted monitor and emits no running boundary")
  func unchangedHealthRefreshDoesNotRestartCollection() async throws {
    let fixture = try makeFixture(context: rawContext())
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }
    let statesBefore = await fixture.repository.stateWrites.count
    let observationsBefore = fixture.platform.observationCount

    await fixture.runtime.refreshGates()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await fixture.repository.stateWrites.count == statesBefore)
    #expect(fixture.platform.observationCount == observationsBefore)
    #expect(fixture.platform.hasObserver)
  }

  @Test("disabled authorization and lifecycle gates never start the monitor")
  func gatesFailClosedWithoutPrompting() async throws {
    for status in [CollectorConsentStatus.unconfirmed, .disabled] {
      let disabled = try makeFixture(
        context: rawContext(),
        consent: status
      )
      await disabled.runtime.start()
      #expect(disabled.runtime.snapshot.status == .disabled)
      #expect(disabled.platform.observationCount == 0)
    }

    let userPaused = try makeFixture(context: rawContext(), consent: .paused)
    await userPaused.runtime.start()
    #expect(userPaused.runtime.snapshot.status == .pausedByUser)
    #expect(userPaused.platform.observationCount == 0)

    let renewalRequired = try makeFixture(
      context: rawContext(),
      renewalRequired: true
    )
    await renewalRequired.runtime.start()
    #expect(renewalRequired.runtime.snapshot.status == .disabled)
    #expect(renewalRequired.platform.observationCount == 0)

    let globallyPaused = try makeFixture(
      context: rawContext(),
      globalPaused: true
    )
    await globallyPaused.runtime.start()
    #expect(globallyPaused.runtime.snapshot.status == .paused([.globalUserPause]))
    #expect(globallyPaused.platform.observationCount == 0)

    let denied = try makeFixture(
      context: rawContext(),
      authorization: .notAuthorized
    )
    await denied.runtime.start()
    #expect(denied.runtime.snapshot.status == .waitingForAuthorization)
    #expect(denied.runtime.snapshot.authorization == .unknown)
    #expect(await denied.repository.stateWrites.last?.record.state.authorization == .unknown)
    #expect(denied.platform.observationCount == 0)

    let inactive = try makeFixture(
      context: rawContext(),
      availability: SystemLifecycleAvailability(
        isUserSessionActive: false,
        areScreensAwake: true
      )
    )
    await inactive.runtime.start()
    #expect(inactive.runtime.snapshot.status == .paused([.userSessionInactive]))
    #expect(inactive.platform.observationCount == 0)
    #expect(
      await inactive.repository.stateWrites.last?.record.state.runtime
        == .paused(
          reasons: [.userSessionInactive],
          resumeState: .running
        ))

    let screensAsleep = try makeFixture(
      context: rawContext(),
      availability: SystemLifecycleAvailability(
        isUserSessionActive: true,
        areScreensAwake: false
      )
    )
    await screensAsleep.runtime.start()
    #expect(screensAsleep.runtime.snapshot.status == .paused([.screensAsleep]))
    #expect(screensAsleep.platform.observationCount == 0)
  }

  @Test("sensitive and malformed observations persist only content-free suppressions")
  func suppressionNeverResolvesOrPersistsContent() async throws {
    let cases: [(RawApplicationWindowContext, CollectionSuppressionReason, Set<String>)] = [
      (rawContext(focusedRole: "AXSecureTextField"), .mandatoryExclusion, []),
      (rawContext(bundleIdentifier: "com.1password.1password"), .passwordManager, []),
      (rawContext(bundleIdentifier: "com.apple.loginwindow"), .authenticationContext, []),
      (rawContext(bundleIdentifier: "com.excluded.app"), .userExclusion, ["com.excluded.app"]),
      (rawContext(bundleIdentifier: " com.example.app"), .uncertainSafetyState, []),
      (rawContext(bundleIdentifier: nil), .uncertainSafetyState, []),
      (rawContext(displayName: nil), .uncertainSafetyState, []),
      (
        rawContext(state: .accessibilityDenied),
        .authorizationUnavailable,
        []
      ),
    ]
    for (context, expectedReason, exclusions) in cases {
      let fixture = try makeFixture(
        context: context,
        excludedBundleIdentifiers: exclusions
      )
      await fixture.runtime.start()
      try await eventually { await fixture.repository.suppressionWrites.count == 1 }

      #expect(await fixture.resolver.callCount == 0)
      #expect(await fixture.repository.applicationWrites.isEmpty)
      let write = await fixture.repository.suppressionWrites.first
      #expect(write?.record.reason == expectedReason)
      #expect(write?.event.securityDisposition == .excluded(expectedReason))
    }
  }

  @Test("Chrome context resolves identity but never persists title or document")
  func chromeContentRemainsNil() async throws {
    for rawBundle in [
      "com.google.Chrome",
      "com.google.chrome.beta",
      "com.google.chrome.canary",
      "org.chromium.Chromium",
      "com.tab-browser.Tabbit",
    ] {
      let fixture = try makeFixture(
        context: rawContext(
          bundleIdentifier: rawBundle,
          title: "Secret tab",
          document: "file:///private/secret.txt"
        ))
      await fixture.runtime.start()
      try await eventually { await fixture.repository.applicationWrites.count == 1 }

      let record = await fixture.repository.applicationWrites.first?.record
      #expect(record?.windowTitleSnapshot == nil)
      #expect(record?.documentFilenameHint == nil)
      #expect(await fixture.resolver.bundleIdentifiers == [rawBundle])
      #expect(!String(reflecting: fixture.runtime.snapshot).contains(rawBundle))
    }
  }

  @Test("consecutive equivalent observations coalesce without inventing time")
  func equivalentObservationsCoalesce() async throws {
    let fixture = try makeFixture(context: rawContext(title: "Same"))
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }

    fixture.platform.send()
    fixture.platform.send()
    fixture.platform.send()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await fixture.repository.applicationWrites.count == 1)

    fixture.platform.currentSnapshot = .context(rawContext(title: "Changed"))
    fixture.platform.send()
    try await eventually { await fixture.repository.applicationWrites.count == 2 }
  }

  @Test("queue overflow preserves FIFO work and one critical failure boundary")
  func overflowUsesReservedBoundarySlot() async throws {
    let fixture = try makeFixture(
      context: rawContext(title: "initial"),
      ordinaryCapacity: 2
    )
    await fixture.repository.blockApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    fixture.platform.currentSnapshot = .context(rawContext(title: "one"))
    fixture.platform.send()
    fixture.platform.currentSnapshot = .context(rawContext(title: "two"))
    fixture.platform.send()
    fixture.platform.currentSnapshot = .context(rawContext(title: "overflow"))
    fixture.platform.send()

    #expect(fixture.runtime.snapshot.status == .degraded(.queueOverflow))
    #expect(!fixture.platform.hasObserver)
    await fixture.repository.releaseApplicationWrites()
    try await eventually { await fixture.repository.applicationWrites.count == 3 }
    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .degraded(.resourcePressure)
    }
    let titles = await fixture.repository.applicationWrites.map {
      $0.record.windowTitleSnapshot
    }
    #expect(titles == ["initial", "one", "two"])
  }

  @Test("storage failure is terminal and suppresses later callbacks")
  func storageFailureStopsProducer() async throws {
    let fixture = try makeFixture(context: rawContext(title: "first"))
    await fixture.repository.failApplicationWrites()
    await fixture.runtime.start()
    try await eventually {
      fixture.runtime.snapshot.status == .failed(.storageUnavailable)
    }

    fixture.platform.currentSnapshot = .context(rawContext(title: "later"))
    fixture.platform.send()
    await fixture.runtime.refreshGates()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await fixture.repository.applicationWrites.isEmpty)
    #expect(!fixture.platform.hasObserver)
    #expect(fixture.runtime.snapshot.status == .failed(.storageUnavailable))
  }

  @Test("history revision advances only after inserted durable commits")
  func revisionWaitsForCommitAndIgnoresAlreadyPresent() async throws {
    let blocked = try makeFixture(context: rawContext(title: "blocked"))
    await blocked.repository.blockApplicationWrites()
    await blocked.runtime.start()
    await blocked.repository.waitUntilApplicationWriteEntered()
    #expect(blocked.runtime.snapshot.historyRevision == 1)
    await blocked.repository.releaseApplicationWrites()
    try await eventually { blocked.runtime.snapshot.historyRevision == 2 }

    let duplicate = try makeFixture(
      context: rawContext(title: "duplicate"),
      applicationInsertResult: .alreadyPresent
    )
    await duplicate.runtime.start()
    try await eventually { await duplicate.repository.applicationWrites.count == 1 }
    #expect(duplicate.runtime.snapshot.historyRevision == 1)
  }

  @Test("storage failure resumes a shutdown already waiting behind the failed write")
  func storageFailureCannotStrandShutdown() async throws {
    let fixture = try makeFixture(context: rawContext(title: "fails"))
    await fixture.repository.blockApplicationWrites()
    await fixture.repository.failApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    let shutdown = Task { await fixture.runtime.shutdown() }
    await Task.yield()
    await fixture.repository.releaseApplicationWrites()
    await shutdown.value

    #expect(fixture.runtime.snapshot.status == .failed(.storageUnavailable))
    #expect(!fixture.platform.hasObserver)
    #expect(await fixture.repository.applicationWrites.isEmpty)
  }

  @Test("storage failure resumes a public refresh waiting behind the failed write")
  func storageFailureCannotStrandRefresh() async throws {
    let fixture = try makeFixture(context: rawContext(title: "fails"))
    await fixture.repository.blockApplicationWrites()
    await fixture.repository.failApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    let refresh = Task { await fixture.runtime.refreshGates() }
    await Task.yield()
    #expect(fixture.platform.hasObserver)
    await fixture.repository.releaseApplicationWrites()
    await refresh.value

    #expect(fixture.runtime.snapshot.status == .failed(.storageUnavailable))
    #expect(!fixture.platform.hasObserver)
    #expect(await fixture.repository.applicationWrites.isEmpty)
  }

  @Test("lifecycle boundary follows admitted FIFO and replaces pending positive reconcile")
  func lifecycleBoundaryOrderingIsFailClosed() async throws {
    let fixture = try makeFixture(
      context: rawContext(title: "initial"),
      ordinaryCapacity: 2
    )
    await fixture.repository.blockApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    fixture.lifecycle.send(.systemDidWake)
    fixture.platform.currentSnapshot = .context(rawContext(title: "second"))
    fixture.platform.send()
    fixture.platform.currentSnapshot = .context(rawContext(title: "third"))
    fixture.platform.send()
    fixture.lifecycle.send(.systemWillSleep)

    #expect(fixture.runtime.snapshot.status == .paused([.systemSleep]))
    #expect(!fixture.platform.hasObserver)
    await fixture.repository.releaseApplicationWrites()
    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .paused(
          reasons: [.systemSleep],
          resumeState: .running
        )
    }
    #expect(
      await fixture.repository.operations == [
        "state", "application", "application", "application", "state",
      ])
  }

  @Test("negative lifecycle preempts a queued public refresh without stranding it")
  func lifecycleBoundaryPreemptsRefreshWaiter() async throws {
    let fixture = try makeFixture(
      context: rawContext(title: "initial"),
      ordinaryCapacity: 2
    )
    await fixture.repository.blockApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    fixture.platform.currentSnapshot = .context(rawContext(title: "queued"))
    fixture.platform.send()
    let refresh = Task { await fixture.runtime.refreshGates() }
    await Task.yield()
    #expect(fixture.platform.hasObserver)
    fixture.lifecycle.send(.systemWillSleep)

    await fixture.repository.releaseApplicationWrites()
    await refresh.value
    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .paused(
          reasons: [.systemSleep],
          resumeState: .running
        )
    }
    #expect(fixture.runtime.snapshot.status == .paused([.systemSleep]))
  }

  @Test("first reserved lifecycle boundary remains authoritative when a second cannot fit")
  func consecutiveNegativeLifecycleBoundariesStayConsistent() async throws {
    let fixture = try makeFixture(
      context: rawContext(title: "initial"),
      ordinaryCapacity: 1
    )
    await fixture.repository.blockApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    fixture.platform.currentSnapshot = .context(rawContext(title: "queued"))
    fixture.platform.send()
    fixture.lifecycle.send(.systemWillSleep)
    #expect(fixture.runtime.snapshot.status == .paused([.systemSleep]))

    fixture.lifecycle.send(.userSessionDidResignActive)
    #expect(
      fixture.runtime.snapshot.status
        == .paused([.systemSleep, .userSessionInactive])
    )

    await fixture.repository.releaseApplicationWrites()
    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .paused(
          reasons: [.systemSleep, .userSessionInactive],
          resumeState: .running
        )
    }
    #expect(
      await fixture.repository.operations == [
        "state", "application", "application", "state", "state",
      ])
    #expect(
      fixture.runtime.snapshot.status
        == .paused([.systemSleep, .userSessionInactive])
    )
  }

  @Test("identity resolution suspension preserves FIFO order")
  func identityResolutionIsSerialized() async throws {
    let fixture = try makeFixture(context: rawContext(title: "first"))
    await fixture.resolver.block()
    await fixture.runtime.start()
    await fixture.resolver.waitUntilEntered()

    fixture.platform.currentSnapshot = .context(rawContext(title: "second"))
    fixture.platform.send()
    await fixture.resolver.release()
    try await eventually { await fixture.repository.applicationWrites.count == 2 }
    #expect(
      await fixture.repository.applicationWrites.map {
        $0.record.windowTitleSnapshot
      } == ["first", "second"])
  }

  @Test("shutdown drains admitted work before its boundary and rejects late callbacks")
  func shutdownWinsWithoutDroppingAdmittedFIFO() async throws {
    let fixture = try makeFixture(
      context: rawContext(title: "admitted"),
      ordinaryCapacity: 2
    )
    await fixture.repository.blockApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    fixture.platform.currentSnapshot = .context(rawContext(title: "queued-one"))
    fixture.platform.send()
    fixture.platform.currentSnapshot = .context(rawContext(title: "queued-two"))
    fixture.platform.send()

    let shutdown = Task { await fixture.runtime.shutdown() }
    try await eventually { !fixture.platform.hasObserver }
    #expect(!fixture.platform.hasObserver)
    fixture.platform.send()
    await fixture.repository.releaseApplicationWrites()
    await shutdown.value

    #expect(await fixture.repository.applicationWrites.count == 3)
    #expect(await fixture.repository.stateWrites.last?.record.state.runtime == .unconfigured)
    #expect(fixture.runtime.snapshot.status == .stopped)
  }

  @Test("screen wake cannot bypass the independent system sleep latch")
  func screenWakeWaitsForSystemWake() async throws {
    let fixture = try makeFixture(context: rawContext(title: "before sleep"))
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }

    fixture.lifecycle.send(.systemWillSleep)
    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .paused(reasons: [.systemSleep], resumeState: .running)
    }
    fixture.lifecycle.availability = SystemLifecycleAvailability(
      isUserSessionActive: true,
      areScreensAwake: true
    )
    fixture.lifecycle.send(.screensDidWake)
    try await Task.sleep(for: .milliseconds(20))
    #expect(!fixture.platform.hasObserver)
    #expect(fixture.runtime.snapshot.status == .paused([.systemSleep]))

    fixture.lifecycle.send(.systemDidWake)
    try await eventually { fixture.platform.hasObserver }
    #expect(fixture.runtime.snapshot.status == .running)
  }

  @Test("live Accessibility loss closes admission and persists state before suppression")
  func liveAuthorizationLossIsFailClosed() async throws {
    let fixture = try makeFixture(context: rawContext(title: "before revoke"))
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }

    fixture.platform.currentSnapshot = .context(
      rawContext(state: .accessibilityDenied, title: "must not survive")
    )
    fixture.platform.send()
    #expect(!fixture.platform.hasObserver)
    try await eventually { await fixture.repository.suppressionWrites.count == 1 }

    #expect(fixture.runtime.snapshot.status == .waitingForAuthorization)
    #expect(fixture.runtime.snapshot.authorization == .revoked)
    #expect(
      await fixture.repository.stateWrites.last?.record.state
        == (try CollectorState(
          kind: .applicationWindowContext,
          authorization: .revoked,
          runtime: .waitingForAuthorization
        )))
    #expect(
      await fixture.repository.suppressionWrites.last?.record.reason == .authorizationUnavailable)
    #expect(await fixture.repository.operations.suffix(2) == ["state", "suppression"])
  }

  @Test("Accessibility denial invalidates an in-flight positive reconcile until explicit refresh")
  func authorizationLossInvalidatesInFlightReconcile() async throws {
    let fixture = try makeFixture(context: rawContext(title: "before race"))
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }
    let baselineStateCount = await fixture.repository.stateWrites.count

    await fixture.consentRepository.blockReads()
    fixture.lifecycle.send(.systemDidWake)
    await fixture.consentRepository.waitUntilReadEntered()

    fixture.platform.currentSnapshot = .context(
      rawContext(state: .accessibilityDenied, title: "must not survive")
    )
    fixture.platform.send()
    #expect(!fixture.platform.hasObserver)
    await fixture.consentRepository.releaseReads()

    try await eventually {
      let suppressionCount = await fixture.repository.suppressionWrites.count
      return fixture.runtime.snapshot.status == .waitingForAuthorization
        && suppressionCount == 1
    }
    let racedStates = await fixture.repository.stateWrites.dropFirst(baselineStateCount)
    #expect(!racedStates.contains { $0.record.state.runtime == .running })
    #expect(fixture.runtime.snapshot.authorization == .revoked)

    fixture.platform.currentSnapshot = .context(rawContext(title: "recovered"))
    await fixture.runtime.refreshGates()
    try await eventually { fixture.runtime.snapshot.status == .running }
    #expect(fixture.runtime.snapshot.authorization == .authorized)
  }

  @Test("authorization-loss partial commit advances history before terminal suppression failure")
  func authorizationLossPartialCommitIsAccounted() async throws {
    let fixture = try makeFixture(context: rawContext(title: "before revoke"))
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }
    #expect(fixture.runtime.snapshot.historyRevision == 2)
    await fixture.repository.failSuppressionWrites()

    fixture.platform.currentSnapshot = .context(rawContext(state: .accessibilityDenied))
    fixture.platform.send()
    try await eventually {
      fixture.runtime.snapshot.status == .failed(.storageUnavailable)
    }

    #expect(fixture.runtime.snapshot.historyRevision == 3)
    #expect(await fixture.repository.suppressionWrites.isEmpty)
    #expect(
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .waitingForAuthorization
    )
  }

  @Test("pending negative control stays closed through refresh and resumes only after release")
  func pendingNegativeControlHoldIsAuthoritative() async throws {
    let fixture = try makeFixture(context: rawContext(title: "before hold"))
    await fixture.runtime.start()
    try await eventually { fixture.platform.hasObserver }

    #expect(await fixture.runtime.beginPendingNegativeControl(.pause))
    #expect(await fixture.runtime.beginPendingNegativeControl(.pause))
    #expect(!(await fixture.runtime.beginPendingNegativeControl(.disable)))
    #expect(!fixture.platform.hasObserver)
    #expect(fixture.runtime.snapshot.status == .holdingNegativeControl(.pause))
    #expect(fixture.runtime.snapshot.pendingNegativeControl == .pause)

    await fixture.runtime.refreshGates()
    #expect(!fixture.platform.hasObserver)
    #expect(fixture.runtime.snapshot.status == .holdingNegativeControl(.pause))
    fixture.runtime.markPendingNegativeControlPersistenceFailed()
    #expect(fixture.runtime.snapshot.status == .failed(.controlPersistenceUnavailable))
    #expect(fixture.runtime.snapshot.pendingNegativeControl == .pause)
    await fixture.runtime.refreshGates()
    #expect(!fixture.platform.hasObserver)
    #expect(fixture.runtime.snapshot.status == .failed(.controlPersistenceUnavailable))
    fixture.lifecycle.send(.systemDidWake)
    try await Task.sleep(for: .milliseconds(10))
    #expect(fixture.runtime.snapshot.status == .failed(.controlPersistenceUnavailable))

    await fixture.runtime.endPendingNegativeControlAndRefresh()
    try await eventually { fixture.platform.hasObserver }
    #expect(fixture.runtime.snapshot.pendingNegativeControl == nil)
    #expect(fixture.runtime.snapshot.status == .running)
  }

  @Test("pending control preserves its admission timestamp through slow persistence")
  func pendingControlPreservesBoundaryTime() async throws {
    let fixture = try makeFixture(context: rawContext(title: "before control"))
    await fixture.runtime.start()
    try await eventually { fixture.runtime.snapshot.status == .running }
    await fixture.repository.blockCollectorStateWrites()

    let controlTime = observedAt.addingTimeInterval(61)
    #expect(
      await fixture.runtime.beginPendingNegativeControl(
        .pause,
        occurredAt: controlTime,
        timeZoneIdentifier: "America/New_York"
      ))
    try await fixture.consentRepository.set(
      status: .paused,
      date: controlTime
    )
    let completion = Task { await fixture.runtime.endPendingNegativeControlAndRefresh() }
    await fixture.repository.waitUntilCollectorStateWriteEntered()
    fixture.clock.set(
      date: controlTime.addingTimeInterval(3_600),
      timeZoneIdentifier: "Asia/Tokyo"
    )
    await fixture.repository.releaseCollectorStateWrites()
    await completion.value

    let boundary = await fixture.repository.stateWrites.last
    #expect(boundary?.event.occurredAt == controlTime)
    #expect(boundary?.event.timeZoneIdentifier == "America/New_York")
    #expect(boundary?.record.state.runtime == .unconfigured)
    #expect(fixture.runtime.snapshot.status == .pausedByUser)
  }

  @Test("a newer serial negative control replaces a preempted boundary context")
  func newerNegativeControlReplacesPreemptedContext() async throws {
    let fixture = try makeFixture(context: rawContext(title: "running"))
    await fixture.runtime.start()
    try await eventually { fixture.runtime.snapshot.status == .running }

    let firstTime = observedAt.addingTimeInterval(10)
    #expect(
      await fixture.runtime.beginPendingNegativeControl(
        .pause,
        occurredAt: firstTime,
        timeZoneIdentifier: "Europe/London"
      ))
    try await fixture.consentRepository.set(status: .paused, date: firstTime)
    await fixture.consentRepository.blockReads()
    let firstCompletion = Task { await fixture.runtime.endPendingNegativeControlAndRefresh() }
    await fixture.consentRepository.waitUntilReadEntered()
    fixture.lifecycle.send(.systemWillSleep)
    await fixture.consentRepository.releaseReads()
    await firstCompletion.value

    let secondTime = observedAt.addingTimeInterval(20)
    #expect(
      await fixture.runtime.beginPendingNegativeControl(
        .disable,
        occurredAt: secondTime,
        timeZoneIdentifier: "America/Chicago"
      ))
    try await fixture.consentRepository.set(status: .disabled, date: secondTime)
    await fixture.runtime.endPendingNegativeControlAndRefresh()

    let finalBoundary = await fixture.repository.stateWrites.last
    #expect(finalBoundary?.record.state.runtime == .unconfigured)
    #expect(finalBoundary?.event.occurredAt == secondTime)
    #expect(finalBoundary?.event.timeZoneIdentifier == "America/Chicago")
  }

  @Test("global pause uses the same-process negative-control boundary time")
  func globalPauseUsesControlBoundaryTime() async throws {
    let fixture = try makeFixture(context: rawContext(title: "running"))
    await fixture.runtime.start()
    try await eventually { fixture.runtime.snapshot.status == .running }
    let controlTime = observedAt.addingTimeInterval(30)

    #expect(
      await fixture.runtime.beginPendingNegativeControl(
        .pause,
        occurredAt: controlTime,
        timeZoneIdentifier: "Australia/Sydney"
      ))
    try await fixture.consentRepository.set(
      status: .enabled,
      globalPaused: true,
      date: controlTime
    )
    await fixture.runtime.endPendingNegativeControlAndRefresh()

    let boundary = await fixture.repository.stateWrites.last
    #expect(
      boundary?.record.state.runtime
        == .paused(reasons: [.globalUserPause], resumeState: .running)
    )
    #expect(boundary?.event.occurredAt == controlTime)
    #expect(boundary?.event.timeZoneIdentifier == "Australia/Sydney")
  }

  @Test("shutdown and hold release are safe before start")
  func preStartBoundariesComplete() async throws {
    let shutdownFixture = try makeFixture(context: rawContext())
    await shutdownFixture.runtime.shutdown()
    #expect(shutdownFixture.runtime.snapshot.status == .stopped)
    #expect(
      await shutdownFixture.repository.stateWrites.last?.record.state.runtime == .unconfigured
    )

    let holdFixture = try makeFixture(context: rawContext())
    #expect(await holdFixture.runtime.beginPendingNegativeControl(.disable))
    await holdFixture.runtime.endPendingNegativeControlAndRefresh()
    #expect(holdFixture.runtime.snapshot.status == .idle)
    #expect(await holdFixture.repository.stateWrites.isEmpty)
    await holdFixture.runtime.shutdown()
    #expect(holdFixture.runtime.snapshot.status == .stopped)
  }

  @Test("runtime consent refresh durably stops disabled paused and renewal-required collection")
  func dynamicConsentRefreshStopsRunningCollection() async throws {
    let cases: [(CollectorConsentStatus, Bool, H1CollectionRuntimeStatus)] = [
      (.disabled, false, .disabled),
      (.paused, false, .pausedByUser),
      (.enabled, true, .disabled),
    ]
    for (status, renewalRequired, expectedStatus) in cases {
      let fixture = try makeFixture(context: rawContext(title: "running"))
      await fixture.runtime.start()
      try await eventually { fixture.runtime.snapshot.status == .running }
      try await fixture.consentRepository.set(
        status: status,
        renewalRequired: renewalRequired,
        date: observedAt.addingTimeInterval(1)
      )

      await fixture.runtime.refreshGates()

      #expect(fixture.runtime.snapshot.status == expectedStatus)
      #expect(!fixture.platform.hasObserver)
      #expect(
        await fixture.repository.stateWrites.last?.record.state.runtime == .unconfigured
      )
    }
  }

  @Test("lifecycle boundary retains callback time and zone behind a slow write")
  func lifecycleBoundaryCapturesAdmissionTime() async throws {
    let fixture = try makeFixture(context: rawContext(title: "initial"))
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }
    await fixture.repository.blockApplicationWrites()

    fixture.platform.currentSnapshot = .context(rawContext(title: "blocked"))
    fixture.platform.send()
    await fixture.repository.waitUntilApplicationWriteEntered()
    let boundaryTime = observedAt.addingTimeInterval(120)
    fixture.clock.set(
      date: boundaryTime,
      timeZoneIdentifier: "America/Los_Angeles"
    )
    fixture.lifecycle.send(.systemWillSleep)
    fixture.clock.set(
      date: boundaryTime.addingTimeInterval(7_200),
      timeZoneIdentifier: "Asia/Tokyo"
    )
    await fixture.repository.releaseApplicationWrites()

    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .paused(reasons: [.systemSleep], resumeState: .running)
    }
    let boundary = await fixture.repository.stateWrites.last
    #expect(boundary?.event.occurredAt == boundaryTime)
    #expect(boundary?.event.timeZoneIdentifier == "America/Los_Angeles")
    let blockedObservation = await fixture.repository.applicationWrites.last
    #expect(blockedObservation?.event.occurredAt == observedAt)
    #expect(blockedObservation?.event.timeZoneIdentifier == "Asia/Shanghai")
  }

  @Test("critical boundary saturation drains accepted FIFO then terminates fail closed")
  func criticalBoundarySaturationDrainsAcceptedWork() async throws {
    let fixture = try makeFixture(
      context: rawContext(title: "initial"),
      ordinaryCapacity: 2,
      maximumBoundaryFacts: 1
    )
    await fixture.repository.blockApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()
    fixture.platform.currentSnapshot = .context(rawContext(title: "queued"))
    fixture.platform.send()

    fixture.lifecycle.send(.systemWillSleep)
    fixture.lifecycle.send(.userSessionDidResignActive)
    #expect(fixture.runtime.snapshot.status == .failed(.queueOverflow))
    await fixture.repository.releaseApplicationWrites()
    await fixture.runtime.shutdown()

    #expect(await fixture.repository.applicationWrites.count == 2)
    #expect(
      await fixture.repository.stateWrites.contains {
        $0.record.state.runtime == .paused(reasons: [.systemSleep], resumeState: .running)
      })
    #expect(
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .degraded(.resourcePressure)
    )
    #expect(fixture.runtime.snapshot.status == .failed(.queueOverflow))
  }

  @Test("equivalent lifecycle callbacks reserve only one durable boundary")
  func duplicateLifecycleBoundariesCoalesce() async throws {
    let fixture = try makeFixture(context: rawContext(title: "initial"))
    await fixture.runtime.start()
    try await eventually { fixture.runtime.snapshot.status == .running }
    await fixture.repository.blockCollectorStateWrites()

    fixture.lifecycle.send(.systemWillSleep)
    await fixture.repository.waitUntilCollectorStateWriteEntered()
    fixture.lifecycle.send(.systemWillSleep)
    await fixture.repository.releaseCollectorStateWrites()
    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .paused(reasons: [.systemSleep], resumeState: .running)
    }
    #expect(
      await fixture.repository.stateWrites.filter {
        $0.record.state.runtime == .paused(reasons: [.systemSleep], resumeState: .running)
      }.count == 1
    )
  }

  @Test("resolver and collector-state failures map to terminal safe statuses")
  func serviceAndStateFailuresAreTerminal() async throws {
    let resolverFailure = try makeFixture(context: rawContext(title: "resolve"))
    await resolverFailure.resolver.fail()
    await resolverFailure.runtime.start()
    try await eventually {
      resolverFailure.runtime.snapshot.status == .failed(.serviceUnavailable)
    }
    await resolverFailure.runtime.shutdown()
    #expect(resolverFailure.runtime.snapshot.status == .failed(.serviceUnavailable))

    let stateFailure = try makeFixture(context: rawContext(title: "state"))
    await stateFailure.repository.failCollectorStateWrites()
    await stateFailure.runtime.start()
    #expect(stateFailure.runtime.snapshot.status == .failed(.storageUnavailable))
    await stateFailure.runtime.shutdown()
    #expect(stateFailure.runtime.snapshot.status == .failed(.storageUnavailable))
  }

  @Test("invalid event metadata maps to invariant failure without a dangerous test seam")
  func invalidMetadataIsInvariantFailure() async throws {
    let fixture = try makeFixture(
      context: rawContext(),
      timeZone: "Not/A-Time-Zone"
    )
    await fixture.runtime.start()
    #expect(fixture.runtime.snapshot.status == .failed(.invariantViolated))
    await fixture.runtime.shutdown()
    #expect(fixture.runtime.snapshot.status == .failed(.invariantViolated))
  }

  @Test("terminal write failure during hold cannot be cleared by releasing the hold")
  func terminalFailureWinsAgainstHoldRelease() async throws {
    let fixture = try makeFixture(context: rawContext(title: "blocked"))
    await fixture.repository.blockApplicationWrites()
    await fixture.repository.failApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()
    #expect(await fixture.runtime.beginPendingNegativeControl(.pause))

    await fixture.repository.releaseApplicationWrites()
    try await eventually {
      fixture.runtime.snapshot.status == .failed(.storageUnavailable)
    }
    await fixture.runtime.endPendingNegativeControlAndRefresh()

    #expect(fixture.runtime.snapshot.status == .failed(.storageUnavailable))
    #expect(fixture.runtime.snapshot.pendingNegativeControl == .pause)
    #expect(!fixture.platform.hasObserver)
  }

  @Test("current and queued control completions each terminate once on storage failure")
  func failureCompletesCurrentAndQueuedControls() async throws {
    let fixture = try makeFixture(context: rawContext(title: "blocked"))
    await fixture.repository.blockApplicationWrites()
    await fixture.repository.failApplicationWrites()
    await fixture.runtime.start()
    await fixture.repository.waitUntilApplicationWriteEntered()

    let firstRefresh = Task { await fixture.runtime.refreshGates() }
    let secondRefresh = Task { await fixture.runtime.refreshGates() }
    let shutdown = Task { await fixture.runtime.shutdown() }
    await Task.yield()
    await fixture.repository.releaseApplicationWrites()
    await firstRefresh.value
    await secondRefresh.value
    await shutdown.value

    #expect(fixture.runtime.snapshot.status == .failed(.storageUnavailable))
    #expect(await fixture.repository.applicationWrites.isEmpty)
    #expect(!fixture.platform.hasObserver)
  }

  @Test("a state boundary permits the same safe application fact after recovery")
  func stateBoundaryResetsDurableCandidateDeduplication() async throws {
    let fixture = try makeFixture(context: rawContext(title: "same"))
    await fixture.runtime.start()
    try await eventually { await fixture.repository.applicationWrites.count == 1 }

    fixture.lifecycle.send(.systemWillSleep)
    try await eventually {
      await fixture.repository.stateWrites.last?.record.state.runtime
        == .paused(reasons: [.systemSleep], resumeState: .running)
    }
    fixture.lifecycle.availability = SystemLifecycleAvailability(
      isUserSessionActive: true,
      areScreensAwake: true
    )
    fixture.lifecycle.send(.systemDidWake)

    try await eventually { await fixture.repository.applicationWrites.count == 2 }
  }

  @Test("status and history factories broadcast independently to multiple subscribers")
  func updateStreamsAreMulticast() async throws {
    let fixture = try makeFixture(context: rawContext(title: "broadcast"))
    var statusA = fixture.runtime.statusUpdates().makeAsyncIterator()
    var statusB = fixture.runtime.statusUpdates().makeAsyncIterator()
    var historyA = fixture.runtime.historyRevisionUpdates().makeAsyncIterator()
    var historyB = fixture.runtime.historyRevisionUpdates().makeAsyncIterator()
    #expect(await statusA.next()?.status == .idle)
    #expect(await statusB.next()?.status == .idle)

    await fixture.runtime.start()
    try await eventually { fixture.runtime.snapshot.historyRevision == 2 }
    #expect(await historyA.next() == 2)
    #expect(await historyB.next() == 2)
    #expect(await statusA.next() != nil)
    #expect(await statusB.next() != nil)
  }

  @Test("concurrent shutdown callers share one durable completion including from hold")
  func concurrentShutdownSharesCompletion() async throws {
    let fixture = try makeFixture(context: rawContext(title: "shutdown"))
    await fixture.runtime.start()
    await fixture.runtime.beginPendingNegativeControl(.disable)

    async let first: Void = fixture.runtime.shutdown()
    async let second: Void = fixture.runtime.shutdown()
    _ = await (first, second)

    #expect(fixture.runtime.snapshot.status == .stopped)
    #expect(await fixture.repository.stateWrites.last?.record.state.runtime == .unconfigured)
    #expect(
      await fixture.repository.stateWrites.filter { $0.record.state.runtime == .unconfigured }.count
        == 1)
  }

  private func makeFixture(
    context: RawApplicationWindowContext,
    consent: CollectorConsentStatus = .enabled,
    renewalRequired: Bool = false,
    globalPaused: Bool = false,
    authorization: CaptureAuthorizationPreflightState = .authorized,
    availability: SystemLifecycleAvailability = SystemLifecycleAvailability(
      isUserSessionActive: true,
      areScreensAwake: true
    ),
    ordinaryCapacity: Int = 8,
    maximumBoundaryFacts: Int = 8,
    clockDate: Date? = nil,
    timeZone: String = "Asia/Shanghai",
    excludedBundleIdentifiers: Set<String> = [],
    applicationInsertResult: ObjectiveEventInsertResult = .inserted
  ) throws -> RuntimeFixture {
    let repository = RecordingLinkedRepository(applicationInsertResult: applicationInsertResult)
    let consentRepository = try TestConsentRepository(
      status: consent,
      globalPaused: globalPaused,
      renewalRequired: renewalRequired,
      date: observedAt
    )
    let platform = RuntimePlatformSource(snapshot: .context(context))
    let lifecycle = RuntimeLifecycleSource(availability: availability)
    let resolver = RecordingIdentityResolver(identifier: applicationID)
    let authorizationPreflight = RuntimeAuthorizationPreflight(state: authorization)
    let testClock = RuntimeTestClock(
      date: clockDate ?? observedAt,
      timeZoneIdentifier: timeZone
    )
    let runtime = H1CollectionRuntime(
      repository: repository,
      consentRepository: consentRepository,
      authorizationPreflight: authorizationPreflight,
      lifecycleSource: lifecycle,
      ordinaryCapacity: ordinaryCapacity,
      maximumBoundaryFacts: maximumBoundaryFacts,
      clock: { testClock.date },
      timeZoneIdentifier: { testClock.timeZoneIdentifier },
      platformSource: platform,
      privacyFilter: DefaultApplicationWindowPrivacyFilter(
        excludedBundleIdentifiers: excludedBundleIdentifiers
      ),
      resolveApplication: { bundleIdentifier, displayLabel in
        try await resolver.resolve(
          bundleIdentifier: bundleIdentifier,
          displayLabel: displayLabel
        )
      }
    )
    return RuntimeFixture(
      runtime: runtime,
      repository: repository,
      platform: platform,
      lifecycle: lifecycle,
      resolver: resolver,
      consentRepository: consentRepository,
      authorizationPreflight: authorizationPreflight,
      clock: testClock
    )
  }

  private func rawContext(
    state: RawApplicationWindowState = .available,
    bundleIdentifier: String? = "com.example.app",
    displayName: String? = "Example App",
    title: String? = "Document",
    document: String? = "file:///Users/person/report.md",
    focusedRole: String? = "AXTextArea"
  ) -> RawApplicationWindowContext {
    RawApplicationWindowContext(
      state: state,
      bundleIdentifier: bundleIdentifier,
      applicationDisplayName: displayName,
      windowTitle: title,
      documentURLString: document,
      windowRole: "AXWindow",
      windowSubrole: "AXStandardWindow",
      focusedElementRole: focusedRole
    )
  }
}

@MainActor
private struct RuntimeFixture {
  let runtime: H1CollectionRuntime
  let repository: RecordingLinkedRepository
  let platform: RuntimePlatformSource
  let lifecycle: RuntimeLifecycleSource
  let resolver: RecordingIdentityResolver
  let consentRepository: TestConsentRepository
  let authorizationPreflight: RuntimeAuthorizationPreflight
  let clock: RuntimeTestClock
}

private actor RecordingLinkedRepository: ObjectiveLinkedRecordRepository {
  private(set) var applicationWrites: [ApplicationContextWrite] = []
  private(set) var suppressionWrites: [CollectionSuppressionWrite] = []
  private(set) var stateWrites: [CollectorStateWrite] = []
  private var shouldFailApplications = false
  private var shouldFailSuppressions = false
  private var shouldFailStates = false
  private var shouldBlockApplications = false
  private var shouldBlockStates = false
  private var applicationEntryWaiters: [CheckedContinuation<Void, Never>] = []
  private var applicationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var enteredApplicationWrite = false
  private var stateEntryWaiters: [CheckedContinuation<Void, Never>] = []
  private var stateReleaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var enteredStateWrite = false
  private let applicationInsertResult: ObjectiveEventInsertResult
  private(set) var operations: [String] = []

  init(applicationInsertResult: ObjectiveEventInsertResult = .inserted) {
    self.applicationInsertResult = applicationInsertResult
  }

  func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult {
    .inserted
  }

  func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] { [] }

  func insertApplicationContext(
    _ write: ApplicationContextWrite
  ) async throws -> ObjectiveEventInsertResult {
    enteredApplicationWrite = true
    let waiters = applicationEntryWaiters
    applicationEntryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if shouldBlockApplications {
      await withCheckedContinuation { applicationReleaseWaiters.append($0) }
    }
    if shouldFailApplications { throw RuntimeTestError.storage }
    applicationWrites.append(write)
    operations.append("application")
    return applicationInsertResult
  }

  func insertCollectorState(
    _ write: CollectorStateWrite
  ) async throws -> ObjectiveEventInsertResult {
    enteredStateWrite = true
    let waiters = stateEntryWaiters
    stateEntryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if shouldBlockStates {
      await withCheckedContinuation { stateReleaseWaiters.append($0) }
    }
    if shouldFailStates { throw RuntimeTestError.storage }
    stateWrites.append(write)
    operations.append("state")
    return .inserted
  }

  func insertCollectionSuppression(
    _ write: CollectionSuppressionWrite
  ) async throws -> ObjectiveEventInsertResult {
    if shouldFailSuppressions { throw RuntimeTestError.storage }
    suppressionWrites.append(write)
    operations.append("suppression")
    return .inserted
  }

  func fetchApplicationContext(for eventID: EventID) async throws -> ApplicationContextRecord? {
    applicationWrites.first { $0.event.id == eventID }?.record
  }

  func fetchCollectorState(for eventID: EventID) async throws -> CollectorStateRecord? {
    stateWrites.first { $0.event.id == eventID }?.record
  }

  func fetchCollectionSuppression(
    for eventID: EventID
  ) async throws -> CollectionSuppressionRecord? {
    suppressionWrites.first { $0.event.id == eventID }?.record
  }

  func blockApplicationWrites() { shouldBlockApplications = true }
  func blockCollectorStateWrites() {
    shouldBlockStates = true
    enteredStateWrite = false
  }
  func failApplicationWrites() { shouldFailApplications = true }
  func failSuppressionWrites() { shouldFailSuppressions = true }
  func failCollectorStateWrites() { shouldFailStates = true }

  func waitUntilApplicationWriteEntered() async {
    if enteredApplicationWrite { return }
    await withCheckedContinuation { applicationEntryWaiters.append($0) }
  }

  func releaseApplicationWrites() {
    shouldBlockApplications = false
    let waiters = applicationReleaseWaiters
    applicationReleaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitUntilCollectorStateWriteEntered() async {
    if enteredStateWrite { return }
    await withCheckedContinuation { stateEntryWaiters.append($0) }
  }

  func releaseCollectorStateWrites() {
    shouldBlockStates = false
    let waiters = stateReleaseWaiters
    stateReleaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private actor TestConsentRepository: CollectionConsentRepository {
  private var storedConsent: PersistedCollectorConsent
  private var storedGlobal: GlobalCollectionControl
  private var shouldBlockReads = false
  private var readEntered = false
  private var readEntryWaiters: [CheckedContinuation<Void, Never>] = []
  private var readReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    status: CollectorConsentStatus,
    globalPaused: Bool,
    renewalRequired: Bool,
    date: Date
  ) throws {
    storedGlobal = GlobalCollectionControl(isPaused: globalPaused, revision: 0)
    storedConsent = try Self.makeConsent(
      status: status,
      renewalRequired: renewalRequired,
      date: date
    )
  }

  private static func makeConsent(
    status: CollectorConsentStatus,
    renewalRequired: Bool,
    date: Date
  ) throws -> PersistedCollectorConsent {
    let initial = CollectorConsent(collector: .applicationWindowContext)
    if status == .unconfirmed {
      return PersistedCollectorConsent(
        consent: initial,
        lastAction: nil,
        revision: 0,
        renewalRequired: renewalRequired
      )
    }
    let confirmation = try UserConsentConfirmation(
      collector: .applicationWindowContext,
      confirmedAt: date,
      disclosureVersion: "1"
    )
    let action: CollectorConsentAction
    switch status {
    case .enabled: action = .enable(confirmation)
    case .disabled: action = .disable(confirmation)
    case .paused:
      let enabled = try CollectorConsentStateMachine.transition(
        .enable(confirmation),
        from: initial
      )
      let paused = try CollectorConsentStateMachine.transition(
        .pause(confirmation),
        from: enabled
      )
      return PersistedCollectorConsent(
        consent: paused,
        lastAction: .pause(confirmation),
        revision: 2,
        renewalRequired: renewalRequired
      )
    case .unconfirmed: preconditionFailure()
    }
    let consent = try CollectorConsentStateMachine.transition(action, from: initial)
    return PersistedCollectorConsent(
      consent: consent,
      lastAction: action,
      revision: 1,
      renewalRequired: renewalRequired
    )
  }

  func consent(for collector: CollectorKind) async throws -> PersistedCollectorConsent {
    readEntered = true
    let waiters = readEntryWaiters
    readEntryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    if shouldBlockReads {
      await withCheckedContinuation { readReleaseWaiters.append($0) }
    }
    return storedConsent
  }

  func transition(
    _ action: CollectorConsentAction,
    expectedRevision: UInt64
  ) async throws -> PersistedCollectorConsent { storedConsent }

  func globalControl() async throws -> GlobalCollectionControl { storedGlobal }

  func setGlobalPaused(
    _ isPaused: Bool,
    expectedRevision: UInt64
  ) async throws -> GlobalCollectionControl { storedGlobal }

  func set(
    status: CollectorConsentStatus,
    renewalRequired: Bool = false,
    globalPaused: Bool? = nil,
    date: Date
  ) throws {
    storedConsent = try Self.makeConsent(
      status: status,
      renewalRequired: renewalRequired,
      date: date
    )
    if let globalPaused {
      storedGlobal = GlobalCollectionControl(
        isPaused: globalPaused,
        revision: storedGlobal.revision &+ 1
      )
    }
  }

  func blockReads() {
    shouldBlockReads = true
    readEntered = false
  }

  func waitUntilReadEntered() async {
    if readEntered { return }
    await withCheckedContinuation { readEntryWaiters.append($0) }
  }

  func releaseReads() {
    shouldBlockReads = false
    let waiters = readReleaseWaiters
    readReleaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}

private final class RuntimeAuthorizationPreflight: CaptureAuthorizationPreflighting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var state: CaptureAuthorizationPreflightState

  init(state: CaptureAuthorizationPreflightState) { self.state = state }

  func snapshot(at date: Date) -> CaptureAuthorizationSnapshot {
    let state = lock.withLock { self.state }
    return CaptureAuthorizationSnapshot(
      screenRecording: .notAuthorized,
      accessibility: state,
      checkedAt: date
    )
  }

  func set(_ state: CaptureAuthorizationPreflightState) {
    lock.withLock { self.state = state }
  }
}

private final class RuntimeTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedDate: Date
  private var storedTimeZoneIdentifier: String

  init(date: Date, timeZoneIdentifier: String) {
    storedDate = date
    storedTimeZoneIdentifier = timeZoneIdentifier
  }

  var date: Date { lock.withLock { storedDate } }
  var timeZoneIdentifier: String { lock.withLock { storedTimeZoneIdentifier } }

  func set(date: Date, timeZoneIdentifier: String) {
    lock.withLock {
      storedDate = date
      storedTimeZoneIdentifier = timeZoneIdentifier
    }
  }
}

@MainActor
private final class RuntimeLifecycleSource: SystemLifecycleNotificationSource {
  var availability: SystemLifecycleAvailability
  private var handler: (@MainActor @Sendable (SystemLifecycleEvent) -> Void)?

  init(availability: SystemLifecycleAvailability) { self.availability = availability }

  func currentAvailability() -> SystemLifecycleAvailability { availability }

  func observe(
    _ handler: @escaping @MainActor @Sendable (SystemLifecycleEvent) -> Void
  ) -> any SystemLifecycleObservation {
    self.handler = handler
    return RuntimeLifecycleObservation { [weak self] in self?.handler = nil }
  }

  func send(_ event: SystemLifecycleEvent) { handler?(event) }
}

@MainActor
private final class RuntimeLifecycleObservation: SystemLifecycleObservation {
  private var cancellation: (@MainActor () -> Void)?
  init(cancellation: @escaping @MainActor () -> Void) { self.cancellation = cancellation }
  func cancel() {
    cancellation?()
    cancellation = nil
  }
}

@MainActor
private final class RuntimePlatformSource: ApplicationWindowPlatformSourcing {
  var currentSnapshot: RawApplicationWindowSnapshot
  private var handler: (@MainActor @Sendable () -> Void)?
  private(set) var observationCount = 0

  init(snapshot: RawApplicationWindowSnapshot) { currentSnapshot = snapshot }
  var hasObserver: Bool { handler != nil }

  func snapshot() -> RawApplicationWindowSnapshot { currentSnapshot }

  func observe(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> any ApplicationWindowPlatformObservation {
    observationCount += 1
    self.handler = handler
    return RuntimePlatformObservation { [weak self] in self?.handler = nil }
  }

  func send() { handler?() }
}

@MainActor
private final class RuntimePlatformObservation: ApplicationWindowPlatformObservation {
  private var cancellation: (@MainActor () -> Void)?
  init(cancellation: @escaping @MainActor () -> Void) { self.cancellation = cancellation }
  var isCurrentApplicationWindowObservationActive: Bool { cancellation != nil }
  func cancel() {
    cancellation?()
    cancellation = nil
  }
}

private actor RecordingIdentityResolver {
  let identifier: ApplicationIdentifier?
  private(set) var bundleIdentifiers: [String] = []
  var callCount: Int { bundleIdentifiers.count }
  private var shouldBlock = false
  private var shouldThrow = false
  private var entered = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(identifier: ApplicationIdentifier?) { self.identifier = identifier }

  func resolve(
    bundleIdentifier: String,
    displayLabel: String
  ) async throws -> ApplicationIdentifier? {
    bundleIdentifiers.append(bundleIdentifier)
    entered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if shouldBlock {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    if shouldThrow { throw RuntimeTestError.service }
    return identifier
  }

  func block() { shouldBlock = true }
  func fail() { shouldThrow = true }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }

  func release() {
    shouldBlock = false
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private enum RuntimeTestError: Error {
  case storage
  case service
}

@MainActor
private func eventually(
  timeout: Duration = .seconds(1),
  condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Condition did not become true before the deadline")
}
