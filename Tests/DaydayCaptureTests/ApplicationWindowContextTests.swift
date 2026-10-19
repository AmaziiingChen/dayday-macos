import DaydayCore
import Foundation
import Testing

@testable import DaydayCapture

@MainActor
@Suite("Application window context")
struct ApplicationWindowContextTests {
  private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("denied Accessibility emits no application or window content")
  func deniedAccessibilityIsExplicitAndContentFree() {
    let platform = TestApplicationWindowPlatformSource(
      snapshot: .context(
        rawContext(
          state: .accessibilityDenied,
          title: "must not escape",
          document: "file:///Users/person/secret.txt"
        )),
      isWindowContentObservationActive: false
    )
    let outputs = FactRecorder()
    let monitor = makeMonitor(platform: platform, outputs: outputs)

    monitor.start()

    let fact = outputs.facts.first
    #expect(fact?.disposition == .accessibilityDenied)
    assertZeroContent(fact)
  }

  @Test("active observation also strips all content from Accessibility denial")
  func activeAccessibilityDenialIsZeroContent() {
    let platform = TestApplicationWindowPlatformSource(
      snapshot: .context(
        rawContext(
          state: .accessibilityDenied,
          title: "must not escape",
          document: "file:///Users/person/secret.txt"
        ))
    )
    let outputs = FactRecorder()
    let monitor = makeMonitor(platform: platform, outputs: outputs)

    monitor.start()

    #expect(outputs.facts.first?.disposition == .accessibilityDenied)
    assertZeroContent(outputs.facts.first)
  }

  @Test("missing focused window remains distinct from denied and unknown")
  func missingFocusedWindowIsExplicit() {
    let platform = TestApplicationWindowPlatformSource(
      snapshot: .context(
        rawContext(
          state: .focusedWindowMissing,
          title: "must not escape",
          document: "file:///private/report.md"
        )))
    let outputs = FactRecorder()
    let monitor = makeMonitor(platform: platform, outputs: outputs)

    monitor.start()

    #expect(outputs.facts.first?.disposition == .focusedWindowMissing)
    #expect(outputs.facts.first?.bundleIdentifier == "com.example.app")
    #expect(outputs.facts.first?.redactedWindowTitle == nil)
    #expect(outputs.facts.first?.redactedDocumentHint == nil)
  }

  @Test("excluded and unknown privacy decisions emit zero content")
  func exclusionAndUnknownFailClosed() {
    for (decision, disposition) in [
      (
        ApplicationWindowPrivacyDecision.excluded(.userExclusion),
        ApplicationWindowContextDisposition.excluded(.userExclusion)
      ),
      (.unknown, .unknownSafetyState),
    ] {
      let platform = TestApplicationWindowPlatformSource(
        snapshot: .context(rawContext())
      )
      let outputs = FactRecorder()
      let monitor = ApplicationWindowContextMonitor(
        testingPlatformSource: platform,
        testingPrivacyFilter: FixedPrivacyFilter(decision: decision),
        clock: { observedAt },
        outputHandler: { outputs.record($0) }
      )

      monitor.start()

      let fact = outputs.facts.first
      #expect(fact?.disposition == disposition)
      #expect(fact?.bundleIdentifier == nil)
      #expect(fact?.applicationDisplayLabel == nil)
      #expect(fact?.redactedWindowTitle == nil)
      #expect(fact?.redactedDocumentHint == nil)
    }
  }

  @Test("Configured host exclusion emits no window content")
  func configuredHostExclusionIsContentFree() {
    let platform = TestApplicationWindowPlatformSource(
      snapshot: .context(rawContext(bundleIdentifier: "app.dayday.local"))
    )
    let outputs = FactRecorder()
    let monitor = ApplicationWindowContextMonitor(
      platformSource: platform,
      excludedBundleIdentifiers: ["app.dayday.local"],
      clock: { observedAt },
      outputHandler: { outputs.record($0) }
    )

    monitor.start()

    let fact = outputs.facts.first
    #expect(fact?.disposition == .excluded(.userExclusion))
    assertZeroContent(fact)
  }

  @Test("long and control text is bounded while URLs and paths are redacted")
  func textFilteringIsBoundedAndRedacted() {
    let rawTitle =
      "  Roadmap\n\u{0007} https://secret.example/path?token=value "
      + String(repeating: "界", count: 200)
    let platform = TestApplicationWindowPlatformSource(
      snapshot: .context(
        rawContext(
          title: rawTitle,
          document: "file:///Users/person/Private/report.md?token=secret"
        )))
    let outputs = FactRecorder()
    let monitor = makeMonitor(platform: platform, outputs: outputs)

    monitor.start()

    let title = outputs.facts.first?.redactedWindowTitle?.value
    let document = outputs.facts.first?.redactedDocumentHint?.value
    #expect(title != nil)
    #expect((title?.utf8.count ?? 0) <= 256)
    #expect(title?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false)
    #expect(!((title ?? "").contains("secret.example")))
    #expect((title ?? "").contains("[redacted-location]"))
    #expect(document == "report.md")
    #expect(!(document ?? "").contains("Users"))
    #expect(!(document ?? "").contains("token"))
  }

  @Test("security-sensitive roles and password managers emit no content")
  func mandatorySensitiveContextsAreExcluded() {
    let cases: [(RawApplicationWindowContext, ApplicationWindowContextExclusionReason)] = [
      (
        rawContext(focusedRole: "AXSecureTextField"),
        .securitySensitiveRole
      ),
      (
        rawContext(bundleIdentifier: "com.1password.1password"),
        .passwordManager
      ),
      (
        rawContext(bundleIdentifier: "com.apple.loginwindow"),
        .authenticationContext
      ),
    ]

    for (rawContext, reason) in cases {
      let platform = TestApplicationWindowPlatformSource(snapshot: .context(rawContext))
      let outputs = FactRecorder()
      let monitor = makeMonitor(platform: platform, outputs: outputs)

      monitor.start()

      let fact = outputs.facts.first
      #expect(fact?.disposition == .excluded(reason))
      #expect(fact?.bundleIdentifier == nil)
      #expect(fact?.applicationDisplayLabel == nil)
      #expect(fact?.redactedWindowTitle == nil)
      #expect(fact?.redactedDocumentHint == nil)
    }
  }

  @Test("a permissive injected policy cannot bypass mandatory exclusions")
  func mandatoryGatePrecedesInjectedPolicy() {
    let permissive = FixedPrivacyFilter(
      decision: .allowed(
        FilteredApplicationWindowContent(
          applicationDisplayLabel: nil,
          redactedWindowTitle: nil,
          redactedDocumentHint: nil
        )
      ))
    let cases: [(RawApplicationWindowContext, ApplicationWindowContextExclusionReason)] = [
      (rawContext(focusedRole: "AXSecureTextField"), .securitySensitiveRole),
      (rawContext(bundleIdentifier: "com.1password.1password"), .passwordManager),
    ]

    for (context, reason) in cases {
      let platform = TestApplicationWindowPlatformSource(snapshot: .context(context))
      let outputs = FactRecorder()
      let monitor = ApplicationWindowContextMonitor(
        testingPlatformSource: platform,
        testingPrivacyFilter: permissive,
        clock: { observedAt },
        outputHandler: { outputs.record($0) }
      )

      monitor.start()

      #expect(outputs.facts.first?.disposition == .excluded(reason))
      assertZeroContent(outputs.facts.first)
    }
  }

  @Test("focused element changes suppress a secure field and teardown rejects late focus events")
  func secureFocusChangeIsImmediateAndLateEventsAreInert() {
    let platform = TestApplicationWindowPlatformSource(
      snapshot: .context(
        rawContext(
          title: "Visible document",
          focusedRole: "AXTextArea"
        )))
    let outputs = FactRecorder()
    let monitor = makeMonitor(platform: platform, outputs: outputs)

    monitor.start()
    #expect(outputs.facts.first?.disposition == .available)
    #expect(outputs.facts.first?.redactedWindowTitle?.value == "Visible document")

    platform.currentSnapshot = .context(
      rawContext(
        title: "must not remain active",
        focusedRole: "AXSecureTextField"
      ))
    platform.send()

    #expect(outputs.facts.count == 2)
    #expect(outputs.facts.last?.disposition == .excluded(.securitySensitiveRole))
    assertZeroContent(outputs.facts.last)

    let lateFocusedElementDelivery = platform.queuedDelivery()
    platform.currentSnapshot = .context(rawContext(title: "late leak"))
    monitor.stop()
    lateFocusedElementDelivery()
    #expect(outputs.facts.count == 2)
  }

  @Test("oversized free-form metadata fails before normalization and mandatory role classification")
  func oversizedMetadataFailsWithinInspectionBudget() {
    let hugeTitle = String(repeating: "界\u{0007}\n", count: 100_000)
    let titlePlatform = TestApplicationWindowPlatformSource(
      snapshot: .context(
        rawContext(
          title: hugeTitle
        )))
    let titleOutputs = FactRecorder()
    makeMonitor(platform: titlePlatform, outputs: titleOutputs).start()

    #expect(titleOutputs.facts.first?.disposition == .available)
    #expect(titleOutputs.facts.first?.redactedWindowTitle == nil)

    for context in [
      rawContext(windowRole: String(repeating: "AXWindow", count: 1_000)),
      rawContext(windowRole: "   "),
      rawContext(focusedRole: String(repeating: "AXTextArea", count: 1_000)),
      rawContext(bundleIdentifier: String(repeating: "com.example.", count: 1_000)),
    ] {
      let platform = TestApplicationWindowPlatformSource(snapshot: .context(context))
      let outputs = FactRecorder()
      makeMonitor(platform: platform, outputs: outputs).start()
      #expect(outputs.facts.first?.disposition == .unknownSafetyState)
      assertZeroContent(outputs.facts.first)
    }
  }

  @Test("relative document hints reject raw encoded and nested query or fragment delimiters")
  func relativeDocumentHintsCannotCarryQueryOrFragment() {
    let unsafeHints = [
      "relative/report.md?token=secret",
      "relative/report.md#private",
      "relative/report.md%3Ftoken=secret",
      "relative/report.md%23private",
      "relative/report.md%253Ftoken=secret",
      "relative/report.md%252525253Ftoken=secret",
    ]

    for hint in unsafeHints {
      let platform = TestApplicationWindowPlatformSource(
        snapshot: .context(
          rawContext(
            document: hint
          )))
      let outputs = FactRecorder()
      makeMonitor(platform: platform, outputs: outputs).start()

      #expect(outputs.facts.first?.disposition == .available)
      #expect(outputs.facts.first?.redactedDocumentHint == nil)
    }
  }

  @Test("window content fails closed when either AX notification is unavailable")
  func partialAXRegistrationFailureEmitsUnknownWithoutContent() {
    let platform = TestApplicationWindowPlatformSource(
      snapshot: .context(rawContext(title: "must not escape")),
      isWindowContentObservationActive: false
    )
    let outputs = FactRecorder()
    let monitor = makeMonitor(platform: platform, outputs: outputs)

    monitor.start()
    #expect(outputs.facts.first?.disposition == .unknownSafetyState)
    assertZeroContent(outputs.facts.first)

    platform.isWindowContentObservationActive = true
    platform.currentSnapshot = .context(rawContext(title: "admitted"))
    platform.send()
    #expect(outputs.facts.last?.disposition == .available)
    #expect(outputs.facts.last?.redactedWindowTitle?.value == "admitted")

    platform.isWindowContentObservationActive = false
    platform.currentSnapshot = .context(rawContext(title: "must be cleared"))
    platform.send()
    #expect(outputs.facts.last?.disposition == .unknownSafetyState)
    assertZeroContent(outputs.facts.last)

    platform.currentSnapshot = .context(
      rawContext(
        state: .accessibilityDenied,
        title: "still must be cleared"
      ))
    platform.send()
    #expect(outputs.facts.last?.disposition == .accessibilityDenied)
    assertZeroContent(outputs.facts.last)
  }

  @Test("supported Chromium bundles suppress browser window content")
  func chromeNeverEmitsDocumentOrBrowserContext() {
    for bundleIdentifier in [
      "com.google.Chrome", "COM.GOOGLE.CHROME.BETA", "com.google.chrome.canary",
      "org.chromium.Chromium", "com.tab-browser.Tabbit",
    ] {
      let platform = TestApplicationWindowPlatformSource(
        snapshot: .context(
          rawContext(
            bundleIdentifier: bundleIdentifier, title: "Project board",
            document: "file:///private/secret.txt")))
      let outputs = FactRecorder()
      makeMonitor(platform: platform, outputs: outputs).start()
      let fact = outputs.facts.first
      #expect(fact?.disposition == .available)
      #expect(fact?.bundleIdentifier == bundleIdentifier)
      #expect(fact?.redactedWindowTitle == nil)
      #expect(fact?.redactedDocumentHint == nil)
    }

    let lookalike = TestApplicationWindowPlatformSource(
      snapshot: .context(
        rawContext(
          bundleIdentifier: "com.google.chrome.lookalike", title: "Ordinary",
          document: "/tmp/note.txt")))
    let lookalikeOutputs = FactRecorder()
    makeMonitor(platform: lookalike, outputs: lookalikeOutputs).start()
    #expect(lookalikeOutputs.facts.first?.redactedWindowTitle?.value == "Ordinary")
    #expect(lookalikeOutputs.facts.first?.redactedDocumentHint?.value == "note.txt")
  }

  @Test("malformed identity and foreground application fail closed")
  func malformedIdentityAndApplicationEmitNoContent() {
    let missingIdentityPlatform = TestApplicationWindowPlatformSource(
      snapshot: .context(rawContext(bundleIdentifier: " com.example.app"))
    )
    let missingIdentityOutputs = FactRecorder()
    let missingIdentityMonitor = ApplicationWindowContextMonitor(
      platformSource: missingIdentityPlatform,
      clock: { observedAt },
      outputHandler: { missingIdentityOutputs.record($0) }
    )
    missingIdentityMonitor.start()
    #expect(missingIdentityOutputs.facts.first?.disposition == .unknownSafetyState)
    assertZeroContent(missingIdentityOutputs.facts.first)

    let missingApplicationPlatform = TestApplicationWindowPlatformSource(
      snapshot: .foregroundApplicationMissing
    )
    let missingApplicationOutputs = FactRecorder()
    makeMonitor(
      platform: missingApplicationPlatform,
      outputs: missingApplicationOutputs
    ).start()
    #expect(
      missingApplicationOutputs.facts.first?.disposition
        == .foregroundApplicationMissing
    )
    assertZeroContent(missingApplicationOutputs.facts.first)
  }

  @Test("start stop and late callbacks are idempotent")
  func teardownRejectsLateDeliveryAndAllowsRestart() {
    let platform = TestApplicationWindowPlatformSource(snapshot: .context(rawContext()))
    let outputs = FactRecorder()
    let monitor = makeMonitor(platform: platform, outputs: outputs)

    monitor.start()
    monitor.start()
    #expect(platform.observationCount == 1)
    #expect(outputs.facts.count == 1)
    let lateDelivery = platform.queuedDelivery()

    monitor.stop()
    monitor.stop()
    #expect(platform.cancellationCount == 1)
    #expect(!monitor.isRunning)
    platform.send()
    lateDelivery()
    #expect(outputs.facts.count == 1)

    monitor.start()
    #expect(platform.observationCount == 2)
    #expect(outputs.facts.count == 2)
    platform.send()
    #expect(outputs.facts.count == 3)
  }

  private func makeMonitor(
    platform: TestApplicationWindowPlatformSource,
    outputs: FactRecorder
  ) -> ApplicationWindowContextMonitor {
    ApplicationWindowContextMonitor(
      platformSource: platform,
      clock: { observedAt },
      outputHandler: { outputs.record($0) }
    )
  }

  private func rawContext(
    state: RawApplicationWindowState = .available,
    bundleIdentifier: String? = "com.example.app",
    title: String? = "Document",
    document: String? = "file:///Users/person/report.md",
    windowRole: String? = "AXWindow",
    focusedRole: String? = "AXTextArea"
  ) -> RawApplicationWindowContext {
    RawApplicationWindowContext(
      state: state,
      bundleIdentifier: bundleIdentifier,
      applicationDisplayName: "Example App",
      windowTitle: title,
      documentURLString: document,
      windowRole: windowRole,
      windowSubrole: "AXStandardWindow",
      focusedElementRole: focusedRole
    )
  }

  private func assertZeroContent(_ fact: FilteredApplicationWindowCandidate?) {
    #expect(fact?.bundleIdentifier == nil)
    #expect(fact?.applicationDisplayLabel == nil)
    #expect(fact?.redactedWindowTitle == nil)
    #expect(fact?.redactedDocumentHint == nil)
  }
}

@MainActor
private final class TestApplicationWindowPlatformSource: ApplicationWindowPlatformSourcing {
  var currentSnapshot: RawApplicationWindowSnapshot
  var isWindowContentObservationActive: Bool
  private var handler: (@MainActor @Sendable () -> Void)?
  private(set) var observationCount = 0
  private(set) var cancellationCount = 0

  init(
    snapshot: RawApplicationWindowSnapshot,
    isWindowContentObservationActive: Bool = true
  ) {
    self.currentSnapshot = snapshot
    self.isWindowContentObservationActive = isWindowContentObservationActive
  }

  func snapshot() -> RawApplicationWindowSnapshot {
    currentSnapshot
  }

  func observe(
    _ handler: @escaping @MainActor @Sendable () -> Void
  ) -> any ApplicationWindowPlatformObservation {
    observationCount += 1
    self.handler = handler
    return TestApplicationWindowObservation(
      readiness: { [weak self] in
        self?.isWindowContentObservationActive == true
      },
      cancellation: { [weak self] in
        guard let self, self.handler != nil else { return }
        self.handler = nil
        self.cancellationCount += 1
      }
    )
  }

  func send() {
    handler?()
  }

  func queuedDelivery() -> @MainActor () -> Void {
    let queuedHandler = handler
    return {
      queuedHandler?()
    }
  }
}

@MainActor
private final class TestApplicationWindowObservation: ApplicationWindowPlatformObservation {
  private let readiness: @MainActor () -> Bool
  private var cancellation: (@MainActor () -> Void)?

  init(
    readiness: @escaping @MainActor () -> Bool,
    cancellation: @escaping @MainActor () -> Void
  ) {
    self.readiness = readiness
    self.cancellation = cancellation
  }

  var isCurrentApplicationWindowObservationActive: Bool { readiness() }

  func cancel() {
    cancellation?()
    cancellation = nil
  }
}

private struct FixedPrivacyFilter: ApplicationWindowPrivacyFiltering {
  let decision: ApplicationWindowPrivacyDecision

  func filter(_ context: RawApplicationWindowContext) -> ApplicationWindowPrivacyDecision {
    decision
  }
}

@MainActor
private final class FactRecorder {
  private(set) var facts: [FilteredApplicationWindowCandidate] = []

  func record(_ fact: FilteredApplicationWindowCandidate) {
    facts.append(fact)
  }
}
