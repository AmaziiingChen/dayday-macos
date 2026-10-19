import DaydayCore
import Testing

@testable import DaydayApp

@Suite("Health dashboard layout preferences")
struct HealthDashboardLayoutPreferencesTests {
  @Test("Malformed storage falls back without hiding available metrics")
  func malformedFallback() {
    let preference = HealthDashboardLayoutPreference.decode("not-json")
    #expect(
      preference.orderedKinds(available: [.heartRate, .stepCount]) == [.heartRate, .stepCount])
  }

  @Test("Order, pin, and compact size survive local encoding")
  func roundTrip() {
    var preference = HealthDashboardLayoutPreference()
    preference.move(.stepCount, before: .heartRate, available: [.heartRate, .stepCount])
    preference.togglePinned(.stepCount)
    preference.setCardSize(.compact, for: .stepCount)

    let decoded = HealthDashboardLayoutPreference.decode(preference.encode())
    #expect(decoded.orderedKinds(available: [.heartRate, .stepCount]) == [.stepCount, .heartRate])
    #expect(decoded.isPinned(.stepCount))
    #expect(decoded.cardSize(for: .stepCount) == .compact)
  }

  @Test("Preset stays bounded to available metrics and preserves the rest")
  func presetIsBounded() {
    let available: [HealthObservationKind] = [.bodyMass, .heartRate, .stepCount]
    var preference = HealthDashboardLayoutPreference()
    preference.apply(.body, available: available)
    #expect(preference.orderedKinds(available: available) == [.bodyMass, .heartRate, .stepCount])
    #expect(Set(preference.orderedKinds(available: available)) == Set(available))
  }

  @Test("Keyboard move is deterministic at list boundaries")
  func boundedMove() {
    let available: [HealthObservationKind] = [.heartRate, .stepCount, .sleepAnalysis]
    var preference = HealthDashboardLayoutPreference()
    preference.move(.heartRate, by: -1, available: available)
    #expect(preference.orderedKinds(available: available) == available)
    preference.move(.heartRate, by: 1, available: available)
    #expect(
      preference.orderedKinds(available: available) == [.stepCount, .heartRate, .sleepAnalysis])
  }
}
