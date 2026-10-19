import DaydayCore
import Foundation

enum HealthMetricCardSize: String, Codable, CaseIterable, Sendable {
  case compact
  case standard

  var title: String {
    switch self {
    case .compact: "紧凑"
    case .standard: "标准"
    }
  }
}

enum HealthDashboardPreset: String, CaseIterable, Identifiable, Sendable {
  case overview
  case daily
  case sleep
  case activity
  case body

  var id: String { rawValue }

  var title: String {
    switch self {
    case .overview: "综合"
    case .daily: "每日"
    case .sleep: "睡眠"
    case .activity: "活动"
    case .body: "身体"
    }
  }

  var preferredKinds: [HealthObservationKind] {
    switch self {
    case .overview:
      [
        .heartRate, .stepCount, .sleepAnalysis, .restingHeartRate, .respiratoryRate,
        .oxygenSaturation, .activeEnergyBurned, .bodyMass,
      ]
    case .daily:
      [
        .stepCount, .activeEnergyBurned, .appleExerciseTime, .appleStandTime,
        .timeInDaylight, .heartRate, .sleepAnalysis,
      ]
    case .sleep:
      [
        .sleepAnalysis, .sleepingWristTemperature, .respiratoryRate, .restingHeartRate,
        .heartRateVariabilitySDNN, .oxygenSaturation,
      ]
    case .activity:
      [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .appleExerciseTime,
        .appleStandTime, .flightsClimbed, .workout, .walkingSpeed,
      ]
    case .body:
      [
        .bodyMass, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass, .height,
        .dietaryWater, .dietaryEnergyConsumed,
      ]
    }
  }
}

struct HealthDashboardLayoutPreference: Codable, Equatable, Sendable {
  static let storageKey = "dayday.health.dashboard-layout.v1"

  private(set) var orderedKindIdentifiers: [String] = []
  private(set) var pinnedKindIdentifiers: Set<String> = []
  private(set) var compactKindIdentifiers: Set<String> = []

  static func decode(_ storedValue: String) -> Self {
    guard let data = storedValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return decoded.normalized()
  }

  func encode() -> String {
    guard let data = try? JSONEncoder().encode(normalized()),
      let value = String(data: data, encoding: .utf8)
    else { return "{}" }
    return value
  }

  func orderedKinds(available: [HealthObservationKind]) -> [HealthObservationKind] {
    let availableSet = Set(available)
    let preferred = orderedKindIdentifiers.compactMap(HealthObservationKind.init(rawValue:))
      .filter { availableSet.contains($0) }
    let missing = available.filter { !preferred.contains($0) }
    return preferred + missing
  }

  func isPinned(_ kind: HealthObservationKind) -> Bool {
    pinnedKindIdentifiers.contains(kind.rawValue)
  }

  func cardSize(for kind: HealthObservationKind) -> HealthMetricCardSize {
    compactKindIdentifiers.contains(kind.rawValue) ? .compact : .standard
  }

  mutating func togglePinned(_ kind: HealthObservationKind) {
    if !pinnedKindIdentifiers.insert(kind.rawValue).inserted {
      pinnedKindIdentifiers.remove(kind.rawValue)
    }
  }

  mutating func setCardSize(_ size: HealthMetricCardSize, for kind: HealthObservationKind) {
    switch size {
    case .compact: compactKindIdentifiers.insert(kind.rawValue)
    case .standard: compactKindIdentifiers.remove(kind.rawValue)
    }
  }

  mutating func move(
    _ kind: HealthObservationKind,
    before target: HealthObservationKind,
    available: [HealthObservationKind]
  ) {
    guard kind != target else { return }
    var order = orderedKinds(available: available)
    guard let sourceIndex = order.firstIndex(of: kind), order.contains(target) else { return }
    let moved = order.remove(at: sourceIndex)
    guard let targetIndex = order.firstIndex(of: target) else { return }
    order.insert(moved, at: targetIndex)
    orderedKindIdentifiers = order.map(\.rawValue)
  }

  mutating func move(
    _ kind: HealthObservationKind,
    by offset: Int,
    available: [HealthObservationKind]
  ) {
    var order = orderedKinds(available: available)
    guard let source = order.firstIndex(of: kind) else { return }
    let destination = min(max(0, source + offset), order.count - 1)
    guard destination != source else { return }
    order.remove(at: source)
    order.insert(kind, at: destination)
    orderedKindIdentifiers = order.map(\.rawValue)
  }

  mutating func apply(_ preset: HealthDashboardPreset, available: [HealthObservationKind]) {
    let availableSet = Set(available)
    let preferred = preset.preferredKinds.filter { availableSet.contains($0) }
    orderedKindIdentifiers = (preferred + available.filter { !preferred.contains($0) }).map(
      \.rawValue)
    pinnedKindIdentifiers = Set(preferred.prefix(3).map(\.rawValue))
  }

  private func normalized() -> Self {
    let valid = Set(HealthObservationKind.allCases.map(\.rawValue))
    var result = self
    var seen = Set<String>()
    result.orderedKindIdentifiers = orderedKindIdentifiers.filter {
      valid.contains($0) && seen.insert($0).inserted
    }
    result.pinnedKindIdentifiers = pinnedKindIdentifiers.intersection(valid)
    result.compactKindIdentifiers = compactKindIdentifiers.intersection(valid)
    return result
  }
}
