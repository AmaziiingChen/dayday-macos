import DaydayCore
import EventKit
import Foundation
import Testing
@testable import DaydayCapture

struct PermissionRequestingTests {
    @Test
    func eventKitWriteOnlyAccessCannotAuthorizeReadCollectors() {
        let result = MacOSPlatformPermissionRequestAdapter.eventKitResult(for: .writeOnly)

        #expect(result == .insufficientAccess)
        #expect(result.authorizationState == .insufficientAccess)
        #expect(!result.authorizationState.permitsCollection)
        #expect(MacOSPlatformPermissionRequestAdapter.eventKitResult(for: .fullAccess) == .authorized)
    }

    @Test
    func accessibilityPromptFalseIsIndeterminateRatherThanADenial() {
        #expect(MacOSPlatformPermissionRequestAdapter.accessibilityResult(isTrusted: true) == .authorized)
        #expect(MacOSPlatformPermissionRequestAdapter.accessibilityResult(isTrusted: false) == .unknown)
    }

    @Test
    func synchronousPromptFalseIsIndeterminateRatherThanADenial() {
        #expect(
            MacOSPlatformPermissionRequestAdapter.indeterminatePromptResult(isAuthorized: true)
                == .authorized
        )
        #expect(
            MacOSPlatformPermissionRequestAdapter.indeterminatePromptResult(isAuthorized: false)
                == .unknown
        )
    }

    @Test
    func insufficientReadAccessReturnsRecoveryWithoutStartingCollection() async throws {
        let requester = ExplicitPermissionRequester(
            adapter: PermissionRequestSpy(result: .insufficientAccess)
        )

        let outcome = await requester.requestPermission(
            for: try enabledConsent(for: .calendar),
            trigger: .userInitiated
        )

        #expect(outcome == .completed(
            authorization: .insufficientAccess,
            recovery: SystemSettingsDeepLinkDescriptor(permission: .calendar)
        ))
    }

    @Test
    func launchPreflightAndAutomaticResumeCanNeverPrompt() async throws {
        let adapter = PermissionRequestSpy(result: .authorized)
        let requester = ExplicitPermissionRequester(adapter: adapter)
        let consent = try enabledConsent(for: .screenUnderstanding)

        for trigger in [
            PermissionRequestTrigger.applicationLaunch,
            .authorizationPreflight,
            .automaticResume
        ] {
            let outcome = await requester.requestPermission(
                for: consent,
                trigger: trigger
            )
            #expect(outcome == .notRequested(.requiresUserInitiatedAction(trigger)))
        }

        let requests = await adapter.requests
        #expect(requests.isEmpty)
    }

    @Test
    func userActionStillRequiresEnabledProductConsent() async throws {
        let adapter = PermissionRequestSpy(result: .authorized)
        let requester = ExplicitPermissionRequester(adapter: adapter)
        let initial = CollectorConsent(collector: .accessibilityCollector)

        let unconfirmed = await requester.requestPermission(
            for: initial,
            trigger: .userInitiated
        )
        #expect(unconfirmed == .notRequested(.productConsentNotEnabled(.unconfirmed)))

        let enabled = try enabledConsent(for: .accessibilityCollector)
        let paused = try CollectorConsentStateMachine.transition(
            .pause(confirmation(for: .accessibilityCollector, at: 200)),
            from: enabled
        )
        let pausedOutcome = await requester.requestPermission(
            for: paused,
            trigger: .userInitiated
        )
        #expect(pausedOutcome == .notRequested(.productConsentNotEnabled(.paused)))
        let requests = await adapter.requests
        #expect(requests.isEmpty)
    }

    @Test
    func everyTCCCollectorRoutesOnlyToItsDeclaredAdapterPermission() async throws {
        let adapter = PermissionRequestSpy(result: .authorized)
        let requester = ExplicitPermissionRequester(adapter: adapter)
        let expected: [(CollectorKind, PlatformPermissionKind)] = [
            (.screenUnderstanding, .screenRecording),
            (.applicationWindowContext, .accessibility),
            (.keyboardAggregates, .inputMonitoring),
            (.pointerAggregates, .inputMonitoring),
            (.calendar, .calendar),
            (.reminders, .reminders)
        ]

        for (collector, permission) in expected {
            let outcome = await requester.requestPermission(
                for: try enabledConsent(for: collector),
                trigger: .userInitiated
            )
            #expect(outcome == .completed(authorization: .authorized, recovery: nil))
            let requests = await adapter.requests
            #expect(requests.last == permission)
        }
        let requests = await adapter.requests
        #expect(requests.count == expected.count)
    }

    @Test
    func chromeAndWeatherNeedProductConsentButNeverInvokeTCCAdapter() async throws {
        let adapter = PermissionRequestSpy(result: .denied)
        let requester = ExplicitPermissionRequester(adapter: adapter)

        for collector in [CollectorKind.chromeContext, .weather] {
            let outcome = await requester.requestPermission(
                for: try enabledConsent(for: collector),
                trigger: .userInitiated
            )
            #expect(outcome == .notRequired)
        }
        let requests = await adapter.requests
        #expect(requests.isEmpty)
    }

    @Test
    func denialAndRevocationReturnRecoverableSystemSettingsDescriptors() async throws {
        let deniedAdapter = PermissionRequestSpy(result: .denied)
        let deniedRequester = ExplicitPermissionRequester(adapter: deniedAdapter)
        let screen = try enabledConsent(for: .screenUnderstanding)

        let denied = await deniedRequester.requestPermission(
            for: screen,
            trigger: .userInitiated
        )
        let screenLink = SystemSettingsDeepLinkDescriptor(permission: .screenRecording)
        #expect(denied == .completed(authorization: .denied, recovery: screenLink))
        #expect(screenLink.url.absoluteString.contains("Privacy_ScreenCapture"))

        let revokedAdapter = PermissionRequestSpy(result: .revoked)
        let revokedRequester = ExplicitPermissionRequester(adapter: revokedAdapter)
        let reminders = await revokedRequester.requestPermission(
            for: try enabledConsent(for: .reminders),
            trigger: .userInitiated
        )
        let remindersLink = SystemSettingsDeepLinkDescriptor(permission: .reminders)
        #expect(reminders == .completed(authorization: .revoked, recovery: remindersLink))
        #expect(remindersLink.url.absoluteString.contains("Privacy_Reminders"))
    }

    @Test
    func systemSettingsDescriptorRoundTripsOnlyPermissionAndDerivesItsURL() throws {
        let descriptor = SystemSettingsDeepLinkDescriptor(permission: .calendar)
        let encoded = try JSONEncoder().encode(descriptor)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: String]
        )

        #expect(object == ["permission": PlatformPermissionKind.calendar.rawValue])

        let decoded = try JSONDecoder().decode(
            SystemSettingsDeepLinkDescriptor.self,
            from: encoded
        )
        #expect(decoded == descriptor)
        #expect(decoded.url.absoluteString.contains("Privacy_Calendars"))
    }

    @Test(arguments: ["https://attacker.invalid/", "file:///tmp/forged"])
    func forgedDescriptorURLCannotOverrideClosedPermissionDestination(
        forgedURL: String
    ) throws {
        let payload = Data(
            #"{"permission":"calendar","url":"\#(forgedURL)"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(
            SystemSettingsDeepLinkDescriptor.self,
            from: payload
        )

        #expect(decoded.permission == .calendar)
        #expect(decoded.url.absoluteString.contains("Privacy_Calendars"))
        #expect(decoded.url.absoluteString != forgedURL)
    }

    @Test
    func requesterReturnsFactsWithoutMutatingConsentOrStartingACollector() async throws {
        let adapter = PermissionRequestSpy(result: .restricted)
        let requester = ExplicitPermissionRequester(adapter: adapter)
        let consent = try enabledConsent(for: .calendar)

        let outcome = await requester.requestPermission(
            for: consent,
            trigger: .userInitiated
        )

        #expect(consent.status == .enabled)
        #expect(outcome == .completed(
            authorization: .restricted,
            recovery: SystemSettingsDeepLinkDescriptor(permission: .calendar)
        ))
    }

    private func enabledConsent(for collector: CollectorKind) throws -> CollectorConsent {
        try CollectorConsentStateMachine.transition(
            .enable(confirmation(for: collector, at: 100)),
            from: CollectorConsent(collector: collector)
        )
    }

    private func confirmation(
        for collector: CollectorKind,
        at timestamp: TimeInterval
    ) throws -> UserConsentConfirmation {
        try UserConsentConfirmation(
            collector: collector,
            confirmedAt: Date(timeIntervalSince1970: timestamp),
            disclosureVersion: "v1"
        )
    }
}

private actor PermissionRequestSpy: PlatformPermissionRequestAdapting {
    private(set) var requests: [PlatformPermissionKind] = []
    let result: PlatformPermissionRequestResult

    init(result: PlatformPermissionRequestResult) {
        self.result = result
    }

    func request(_ permission: PlatformPermissionKind) async -> PlatformPermissionRequestResult {
        requests.append(permission)
        return result
    }
}

private extension CollectorKind {
    static let accessibilityCollector = CollectorKind.applicationWindowContext
}
