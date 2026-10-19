import DaydayCore
import Foundation
import Testing

struct CollectionControlTests {
  @Test
  func persistedConsentMakesRenewalFailClosed() throws {
    let confirmation = try UserConsentConfirmation(
      collector: .keyboardAggregates,
      confirmedAt: Date(timeIntervalSince1970: 10),
      disclosureVersion: "dayday-consent-v1"
    )
    let enabled = try CollectorConsentStateMachine.transition(
      .enable(confirmation), from: CollectorConsent(collector: .keyboardAggregates))
    let persisted = PersistedCollectorConsent(
      consent: enabled, lastAction: .enable(confirmation), revision: 1, renewalRequired: true)

    #expect(persisted.lastAction == .enable)
    #expect(!persisted.permitsCollection)
  }

  @Test
  func stopIntentIsBoundedToItsScopeAndRevision() throws {
    let confirmation = try UserConsentConfirmation(
      collector: .screenUnderstanding,
      confirmedAt: Date(timeIntervalSince1970: 20),
      disclosureVersion: "dayday-consent-v1"
    )
    let intent = try CollectionStopIntent(
      scope: .collector(.screenUnderstanding), target: .collectorDisabled,
      confirmation: confirmation, expectedRevision: 4, targetRevision: 5
    )
    #expect(intent.targetRevision == 5)
    #expect(throws: CollectionConsentRepositoryError.corruptedValue) {
      _ = try CollectionStopIntent(
        scope: .global, target: .collectorPaused, confirmation: nil, expectedRevision: 0,
        targetRevision: 1)
    }
    #expect(throws: CollectionConsentRepositoryError.revisionOutOfRange) {
      _ = try CollectionStopIntent(
        scope: .global, target: .globalPaused, confirmation: nil, expectedRevision: UInt64.max,
        targetRevision: 0)
    }
    #expect(throws: CollectionConsentRepositoryError.corruptedValue) {
      _ = try CollectionStopIntent(
        scope: .global, target: .globalPaused, confirmation: nil, expectedRevision: 3,
        targetRevision: 5)
    }
  }
}
