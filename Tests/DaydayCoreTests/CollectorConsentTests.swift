import Foundation
import Testing
@testable import DaydayCore

struct CollectorConsentTests {
    @Test
    func everyCollectorHasACompleteIndependentDisclosure() {
        let disclosures = CollectorKind.allCases.map(\CollectorKind.consentDisclosure)

        #expect(disclosures.count == CollectorKind.allCases.count)
        #expect(Set(disclosures.map(\CollectorConsentDisclosure.collector)) == Set(CollectorKind.allCases))
        for disclosure in disclosures {
            #expect(!disclosure.purpose.isEmpty)
            #expect(!disclosure.collectedSummary.isEmpty)
            #expect(!disclosure.notCollectedSummary.isEmpty)
        }

        #expect(CollectorKind.screenUnderstanding.consentDisclosure.permissionRequirement == .tcc(.screenRecording))
        #expect(CollectorKind.applicationWindowContext.consentDisclosure.permissionRequirement == .tcc(.accessibility))
        #expect(CollectorKind.keyboardAggregates.consentDisclosure.permissionRequirement == .tcc(.inputMonitoring))
        #expect(CollectorKind.pointerAggregates.consentDisclosure.permissionRequirement == .tcc(.inputMonitoring))
        #expect(CollectorKind.calendar.consentDisclosure.permissionRequirement == .tcc(.calendar))
        #expect(CollectorKind.reminders.consentDisclosure.permissionRequirement == .tcc(.reminders))
        #expect(CollectorKind.chromeContext.consentDisclosure.permissionRequirement == .notRequired)
        #expect(CollectorKind.weather.consentDisclosure.permissionRequirement == .notRequired)
    }

    @Test
    func newConsentIsInertUntilExplicitUserConfirmation() {
        let consent = CollectorConsent(collector: .screenUnderstanding)

        #expect(consent.status == .unconfirmed)
        #expect(consent.confirmation == nil)
        #expect(!consent.permitsPermissionRequest)
        #expect(!consent.permitsCollection)
    }

    @Test
    func enabledPausedResumedAndDisabledAreExplicitIndependentProductStates() throws {
        let initial = CollectorConsent(collector: .keyboardAggregates)
        let enabledConfirmation = try confirmation(
            collector: .keyboardAggregates,
            timestamp: 100
        )
        let enabled = try CollectorConsentStateMachine.transition(
            .enable(enabledConfirmation),
            from: initial
        )
        #expect(enabled.status == .enabled)
        #expect(enabled.permitsPermissionRequest)
        #expect(enabled.permitsCollection)

        let pausedConfirmation = try confirmation(
            collector: .keyboardAggregates,
            timestamp: 200
        )
        let paused = try CollectorConsentStateMachine.transition(
            .pause(pausedConfirmation),
            from: enabled
        )
        #expect(paused.status == .paused)
        #expect(!paused.permitsPermissionRequest)
        #expect(!paused.permitsCollection)

        let resumedConfirmation = try confirmation(
            collector: .keyboardAggregates,
            timestamp: 300
        )
        let resumed = try CollectorConsentStateMachine.transition(
            .resume(resumedConfirmation),
            from: paused
        )
        #expect(resumed.status == .enabled)
        #expect(resumed.confirmation == resumedConfirmation)

        let disabledConfirmation = try confirmation(
            collector: .keyboardAggregates,
            timestamp: 400
        )
        let disabled = try CollectorConsentStateMachine.transition(
            .disable(disabledConfirmation),
            from: resumed
        )
        #expect(disabled.status == .disabled)
        #expect(!disabled.permitsPermissionRequest)
        #expect(!disabled.permitsCollection)
    }

    @Test
    func stateMachineRejectsImplicitOrMismatchedTransitions() throws {
        let screen = CollectorConsent(collector: .screenUnderstanding)
        let chromeConfirmation = try confirmation(collector: .chromeContext)

        #expect(throws: CollectorConsentTransitionError.confirmationCollectorMismatch) {
            try CollectorConsentStateMachine.transition(
                .enable(chromeConfirmation),
                from: screen
            )
        }

        let screenConfirmation = try confirmation(collector: .screenUnderstanding)
        #expect(throws: CollectorConsentTransitionError.cannotPause(.unconfirmed)) {
            try CollectorConsentStateMachine.transition(
                .pause(screenConfirmation),
                from: screen
            )
        }
        #expect(throws: CollectorConsentTransitionError.cannotResume(.unconfirmed)) {
            try CollectorConsentStateMachine.transition(
                .resume(screenConfirmation),
                from: screen
            )
        }
    }

    @Test
    func decodingCannotForgeConfirmedStateWithoutMatchingConfirmation() throws {
        let missing = Data(#"{"collector":"weather","status":"enabled"}"#.utf8)
        #expect(throws: CollectorConsent.ValidationError.missingConfirmation) {
            try JSONDecoder().decode(CollectorConsent.self, from: missing)
        }

        let wrongCollector = Data(#"{"collector":"weather","status":"enabled","confirmation":{"collector":"chromeContext","confirmedAt":0,"disclosureVersion":"1"}}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(throws: CollectorConsent.ValidationError.confirmationCollectorMismatch) {
            try decoder.decode(CollectorConsent.self, from: wrongCollector)
        }

        let unexpected = Data(#"{"collector":"weather","status":"unconfirmed","confirmation":{"collector":"weather","confirmedAt":0,"disclosureVersion":"1"}}"#.utf8)
        #expect(throws: CollectorConsent.ValidationError.unexpectedConfirmation) {
            try decoder.decode(CollectorConsent.self, from: unexpected)
        }
    }

    @Test
    func confirmationMetadataRejectsUnboundedOrNonFiniteValues() {
        #expect(throws: UserConsentConfirmation.ValidationError.invalidTimestamp) {
            try UserConsentConfirmation(
                collector: .weather,
                confirmedAt: Date(timeIntervalSinceReferenceDate: .nan),
                disclosureVersion: "1"
            )
        }
        #expect(throws: UserConsentConfirmation.ValidationError.invalidDisclosureVersion) {
            try UserConsentConfirmation(
                collector: .weather,
                confirmedAt: .distantPast,
                disclosureVersion: "contains private prose"
            )
        }
    }

    private func confirmation(
        collector: CollectorKind,
        timestamp: TimeInterval = 100
    ) throws -> UserConsentConfirmation {
        try UserConsentConfirmation(
            collector: collector,
            confirmedAt: Date(timeIntervalSince1970: timestamp),
            disclosureVersion: "v1"
        )
    }
}
