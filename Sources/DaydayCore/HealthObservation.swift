import Foundation

/// A closed, non-clinical vocabulary shared by the local health archive. New kinds require an
/// explicit privacy and storage decision; the archive never accepts an opaque "all HealthKit" key.
public enum HealthObservationKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
  case heartRate, restingHeartRate, heartRateVariabilitySDNN, respiratoryRate, oxygenSaturation
  case walkingHeartRateAverage, vo2Max, sleepingWristTemperature
  case stepCount, distanceWalkingRunning, distanceCycling, flightsClimbed
  case activeEnergyBurned, basalEnergyBurned, appleExerciseTime, appleStandTime, appleMoveTime
  case timeInDaylight, workout
  case bodyMass, bodyMassIndex, height, bodyFatPercentage, leanBodyMass
  case sleepAnalysis, mindfulSession, appleStandHour
  case walkingSpeed, walkingStepLength, walkingAsymmetryPercentage, walkingDoubleSupportPercentage
  case appleWalkingSteadiness, stairAscentSpeed, stairDescentSpeed, sixMinuteWalkTestDistance
  case runningSpeed, runningPower, runningStrideLength, runningGroundContactTime,
    runningVerticalOscillation
  case dietaryWater, dietaryEnergyConsumed, dietaryProtein, dietaryCarbohydrates, dietaryFatTotal
  case dietarySugar, dietaryFiber, dietarySodium, dietaryCaffeine
  case headphoneAudioExposure, environmentalAudioExposure

  public var id: String { rawValue }
}

public struct HealthObservationKey: Codable, Hashable, Sendable {
  public let sourceInstallationID: UUID
  public let healthKitUUID: UUID

  public init(sourceInstallationID: UUID, healthKitUUID: UUID) {
    self.sourceInstallationID = sourceInstallationID
    self.healthKitUUID = healthKitUUID
  }
}

public struct HealthObservationSource: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case missingName, missingBundleIdentifier
  }

  public let name: String
  public let bundleIdentifier: String

  public init(name: String, bundleIdentifier: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.missingName
    }
    guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.missingBundleIdentifier
    }
    self.name = name
    self.bundleIdentifier = bundleIdentifier
  }
}

public enum HealthObservationPayload: Codable, Hashable, Sendable {
  case quantity(value: Double, unit: String)
  case category(rawValue: Int)
  case workout(activityType: UInt, duration: TimeInterval, activeEnergyKilocalories: Double?)

  public enum ValidationError: Error, Equatable, Sendable {
    case nonFiniteValue, missingUnit, invalidDuration
  }

  private enum CodingKeys: String, CodingKey {
    case kind, value, unit, rawValue, activityType, duration, activeEnergyKilocalories
  }
  private enum Kind: String, Codable { case quantity, category, workout }

  public init(quantityValue value: Double, unit: String) throws {
    guard value.isFinite else { throw ValidationError.nonFiniteValue }
    guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError.missingUnit
    }
    self = .quantity(value: value, unit: unit)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .quantity(let value, let unit):
      guard value.isFinite else { throw ValidationError.nonFiniteValue }
      guard !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError.missingUnit
      }
      try container.encode(Kind.quantity, forKey: .kind)
      try container.encode(value, forKey: .value)
      try container.encode(unit, forKey: .unit)
    case .category(let rawValue):
      try container.encode(Kind.category, forKey: .kind)
      try container.encode(rawValue, forKey: .rawValue)
    case .workout(let activityType, let duration, let activeEnergyKilocalories):
      guard duration.isFinite, duration >= 0 else { throw ValidationError.invalidDuration }
      guard activeEnergyKilocalories?.isFinite ?? true else { throw ValidationError.nonFiniteValue }
      try container.encode(Kind.workout, forKey: .kind)
      try container.encode(activityType, forKey: .activityType)
      try container.encode(duration, forKey: .duration)
      try container.encode(activeEnergyKilocalories, forKey: .activeEnergyKilocalories)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .quantity:
      try self.init(
        quantityValue: container.decode(Double.self, forKey: .value),
        unit: container.decode(String.self, forKey: .unit)
      )
    case .category:
      self = .category(rawValue: try container.decode(Int.self, forKey: .rawValue))
    case .workout:
      let duration = try container.decode(TimeInterval.self, forKey: .duration)
      let energy = try container.decodeIfPresent(Double.self, forKey: .activeEnergyKilocalories)
      guard duration.isFinite, duration >= 0 else { throw ValidationError.invalidDuration }
      guard energy?.isFinite ?? true else { throw ValidationError.nonFiniteValue }
      self = .workout(
        activityType: try container.decode(UInt.self, forKey: .activityType),
        duration: duration,
        activeEnergyKilocalories: energy
      )
    }
  }
}

/// One user-authorized, factual Apple Health observation. It contains no derived summary,
/// diagnosis, score, journal text, work context, route, document, or clinical record.
public struct HealthObservation: Codable, Hashable, Sendable, Identifiable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidTimeRange, invalidReceivedAt
  }

  public let key: HealthObservationKey
  public let kind: HealthObservationKind
  public let startedAt: Date
  public let endedAt: Date
  public let source: HealthObservationSource
  public let payload: HealthObservationPayload
  public let receivedAt: Date

  public var id: HealthObservationKey { key }

  public init(
    key: HealthObservationKey,
    kind: HealthObservationKind,
    startedAt: Date,
    endedAt: Date,
    source: HealthObservationSource,
    payload: HealthObservationPayload,
    receivedAt: Date
  ) throws {
    guard startedAt.timeIntervalSinceReferenceDate.isFinite,
      endedAt.timeIntervalSinceReferenceDate.isFinite,
      startedAt <= endedAt
    else { throw ValidationError.invalidTimeRange }
    guard receivedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.invalidReceivedAt
    }
    self.key = key
    self.kind = kind
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.source = source
    self.payload = payload
    self.receivedAt = receivedAt
  }
}

public struct HealthObservationTombstone: Codable, Hashable, Sendable, Identifiable {
  public enum ValidationError: Error, Equatable, Sendable { case invalidDeletedAt }

  public let key: HealthObservationKey
  public let kind: HealthObservationKind
  public let deletedAt: Date

  public var id: HealthObservationKey { key }

  public init(key: HealthObservationKey, kind: HealthObservationKind, deletedAt: Date) throws {
    guard deletedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.invalidDeletedAt
    }
    self.key = key
    self.kind = kind
    self.deletedAt = deletedAt
  }
}

/// Atomic receive unit for an eventually-consistent local device transfer. The same batch ID may
/// be safely retried, but a conflicting reuse is rejected rather than silently merged.
public struct HealthArchiveBatch: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidCreatedAt, observationFromOtherSource, tombstoneFromOtherSource
    case duplicateObservation, duplicateTombstone, observationAndTombstoneConflict
  }

  public let batchID: UUID
  public let sourceInstallationID: UUID
  public let createdAt: Date
  public let observations: [HealthObservation]
  public let tombstones: [HealthObservationTombstone]

  public init(
    batchID: UUID = UUID(),
    sourceInstallationID: UUID,
    createdAt: Date,
    observations: [HealthObservation],
    tombstones: [HealthObservationTombstone]
  ) throws {
    guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.invalidCreatedAt
    }
    guard observations.allSatisfy({ $0.key.sourceInstallationID == sourceInstallationID }) else {
      throw ValidationError.observationFromOtherSource
    }
    guard tombstones.allSatisfy({ $0.key.sourceInstallationID == sourceInstallationID }) else {
      throw ValidationError.tombstoneFromOtherSource
    }
    let observationKeys = observations.map(\.key)
    let tombstoneKeys = tombstones.map(\.key)
    guard Set(observationKeys).count == observationKeys.count else {
      throw ValidationError.duplicateObservation
    }
    guard Set(tombstoneKeys).count == tombstoneKeys.count else {
      throw ValidationError.duplicateTombstone
    }
    guard Set(observationKeys).isDisjoint(with: Set(tombstoneKeys)) else {
      throw ValidationError.observationAndTombstoneConflict
    }
    self.batchID = batchID
    self.sourceInstallationID = sourceInstallationID
    self.createdAt = createdAt
    self.observations = observations
    self.tombstones = tombstones
  }
}

/// The only successful response to a health archive upload. The acknowledgement is sent only
/// after the receiver has committed the entire batch transaction, so an interrupted connection
/// can safely retry the same batch ID.
public struct HealthSyncAcknowledgement: Codable, Hashable, Sendable {
  public let sourceInstallationID: UUID
  public let batchID: UUID
  public let receivedAt: Date

  public init(sourceInstallationID: UUID, batchID: UUID, receivedAt: Date) {
    self.sourceInstallationID = sourceInstallationID
    self.batchID = batchID
    self.receivedAt = receivedAt
  }
}

public struct HealthArchiveQuery: Sendable, Equatable {
  public enum ValidationError: Error, Equatable, Sendable { case invalidLimit, invalidDateRange }

  public let kinds: Set<HealthObservationKind>?
  public let startsAtOrAfter: Date?
  public let endsAtOrBefore: Date?
  public let limit: Int

  public init(
    kinds: Set<HealthObservationKind>? = nil,
    startsAtOrAfter: Date? = nil,
    endsAtOrBefore: Date? = nil,
    limit: Int = 200
  ) throws {
    guard (1...100_000).contains(limit) else { throw ValidationError.invalidLimit }
    if let startsAtOrAfter, let endsAtOrBefore {
      guard startsAtOrAfter <= endsAtOrBefore else { throw ValidationError.invalidDateRange }
    }
    self.kinds = kinds
    self.startsAtOrAfter = startsAtOrAfter
    self.endsAtOrBefore = endsAtOrBefore
    self.limit = limit
  }
}

/// An explicit, local-only deletion instruction. It can only target named kinds and a bounded
/// time range, which prevents an accidental "clear archive" action. Deleting a record here never
/// writes to Apple Health or asks the Companion to delete its source record.
public struct HealthArchiveDeletionRequest: Sendable, Equatable {
  public enum ValidationError: Error, Equatable, Sendable {
    case emptyKinds, missingDateRange, invalidDateRange
  }

  public let kinds: Set<HealthObservationKind>
  public let startsAtOrAfter: Date
  public let endsAtOrBefore: Date

  public init(
    kinds: Set<HealthObservationKind>,
    startsAtOrAfter: Date?,
    endsAtOrBefore: Date?
  ) throws {
    guard !kinds.isEmpty else { throw ValidationError.emptyKinds }
    guard let startsAtOrAfter, let endsAtOrBefore else { throw ValidationError.missingDateRange }
    guard startsAtOrAfter <= endsAtOrBefore else { throw ValidationError.invalidDateRange }
    self.kinds = kinds
    self.startsAtOrAfter = startsAtOrAfter
    self.endsAtOrBefore = endsAtOrBefore
  }
}

public struct HealthArchiveDeletionResult: Equatable, Sendable {
  public let removedObservationCount: Int

  public init(removedObservationCount: Int) {
    self.removedObservationCount = removedObservationCount
  }
}

/// A portable factual snapshot created only after the user chooses an export location. This is
/// deliberately separate from the transfer batch: it includes no pairing credential, queue state,
/// journal, work report, or AI inference.
public struct HealthArchiveExport: Codable, Sendable, Equatable {
  public static let format = "dayday-health-archive/v1"

  public let format: String
  public let exportedAt: Date
  public let observations: [HealthObservation]

  public init(exportedAt: Date, observations: [HealthObservation]) {
    self.format = Self.format
    self.exportedAt = exportedAt
    self.observations = observations
  }
}

public struct HealthObservationCoverage: Codable, Hashable, Sendable, Identifiable {
  public let kind: HealthObservationKind
  public let observationCount: Int
  public let latestEndedAt: Date?

  public var id: HealthObservationKind { kind }

  public init(kind: HealthObservationKind, observationCount: Int, latestEndedAt: Date?) {
    self.kind = kind
    self.observationCount = observationCount
    self.latestEndedAt = latestEndedAt
  }
}

/// A bounded request for objective archive statistics. Day buckets use the Mac's current
/// calendar/time-zone presentation; the archive remains keyed by absolute HealthKit timestamps.
public struct HealthArchiveStatisticsQuery: Equatable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidDateRange, dateRangeTooLarge, invalidRecentSyncLimit
  }

  public let kinds: Set<HealthObservationKind>?
  public let startsAt: Date
  public let endsAt: Date
  public let recentSyncLimit: Int

  public init(
    kinds: Set<HealthObservationKind>? = nil,
    startsAt: Date,
    endsAt: Date,
    recentSyncLimit: Int = 8
  ) throws {
    guard startsAt <= endsAt else { throw ValidationError.invalidDateRange }
    guard endsAt.timeIntervalSince(startsAt) <= 367 * 24 * 60 * 60 else {
      throw ValidationError.dateRangeTooLarge
    }
    guard (1...20).contains(recentSyncLimit) else { throw ValidationError.invalidRecentSyncLimit }
    self.kinds = kinds
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.recentSyncLimit = recentSyncLimit
  }
}

/// Whole-archive counters used by the sync overview. They deliberately contain no health values.
public struct HealthArchiveSummary: Codable, Equatable, Sendable {
  public let observationCount: Int
  public let coveredKindCount: Int
  public let sourceInstallationCount: Int
  public let receivedBatchCount: Int
  public let earliestEndedAt: Date?
  public let latestEndedAt: Date?
  public let latestBatchReceivedAt: Date?

  public init(
    observationCount: Int,
    coveredKindCount: Int,
    sourceInstallationCount: Int,
    receivedBatchCount: Int,
    earliestEndedAt: Date?,
    latestEndedAt: Date?,
    latestBatchReceivedAt: Date?
  ) {
    self.observationCount = observationCount
    self.coveredKindCount = coveredKindCount
    self.sourceInstallationCount = sourceInstallationCount
    self.receivedBatchCount = receivedBatchCount
    self.earliestEndedAt = earliestEndedAt
    self.latestEndedAt = latestEndedAt
    self.latestBatchReceivedAt = latestBatchReceivedAt
  }
}

/// A content-free receipt for one batch committed by the Mac archive.
public struct HealthSyncReceipt: Codable, Equatable, Sendable, Identifiable {
  public let batchID: UUID
  public let receivedAt: Date
  public let observationCount: Int
  public let tombstoneCount: Int

  public var id: UUID { batchID }

  public init(batchID: UUID, receivedAt: Date, observationCount: Int, tombstoneCount: Int) {
    self.batchID = batchID
    self.receivedAt = receivedAt
    self.observationCount = observationCount
    self.tombstoneCount = tombstoneCount
  }
}

/// One local-calendar day of record density. This is a data-volume fact, not a health score.
public struct HealthArchiveDayCount: Codable, Equatable, Sendable, Identifiable {
  public let logicalDate: String
  public let observationCount: Int

  public var id: String { logicalDate }

  public init(logicalDate: String, observationCount: Int) {
    self.logicalDate = logicalDate
    self.observationCount = observationCount
  }
}

/// The aggregation that turns factual HealthKit samples into one chart value.
///
/// This is presentation-neutral and deliberately mirrors HealthKit's public statistics vocabulary:
/// discrete quantities such as heart rate use an average, cumulative quantities such as steps use
/// a sum, and sleep categories contribute their factual interval duration.
public enum HealthMetricAggregation: String, Codable, Hashable, Sendable {
  case discreteAverage
  case cumulativeSum
  case duration
}

/// Canonical units used by bounded health-dashboard projections. Raw HealthKit unit strings remain
/// preserved on every observation; this normalized unit only prevents UI code from guessing how a
/// dashboard value should be formatted.
public enum HealthMetricUnit: String, Codable, Hashable, Sendable {
  case beatsPerMinute
  case countPerMinute
  case count
  case seconds
  case minutes
  case milliseconds
  case percentage
  case meters
  case metersPerSecond
  case kilocalories
  case kilograms
  case milligrams
  case liters
  case degreesCelsius
  case millilitersPerKilogramMinute
  case watts
  case decibels
}

/// One bounded aggregate point derived from objective samples.
public struct HealthMetricPoint: Codable, Hashable, Sendable, Identifiable {
  public let startedAt: Date
  public let endedAt: Date
  public let value: Double
  public let minimum: Double?
  public let maximum: Double?
  public let contributingSampleCount: Int

  public var id: Date { startedAt }

  public init(
    startedAt: Date,
    endedAt: Date,
    value: Double,
    minimum: Double? = nil,
    maximum: Double? = nil,
    contributingSampleCount: Int
  ) {
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
    self.contributingSampleCount = contributingSampleCount
  }
}

/// A compact metric projection kept alongside the archive dashboard cache. It contains at most one
/// point per day plus bounded, fine-grained points for the latest seven local days. Recent points
/// remain deterministic aggregates rather than individual archive payloads, so opening the page
/// never loads the full factual archive into SwiftUI.
public struct HealthMetricSeries: Codable, Hashable, Sendable, Identifiable {
  public let kind: HealthObservationKind
  public let aggregation: HealthMetricAggregation
  public let unit: HealthMetricUnit
  public let latestSample: HealthMetricPoint?
  public let dailyPoints: [HealthMetricPoint]
  public let intradayPoints: [HealthMetricPoint]

  public var id: HealthObservationKind { kind }

  public init(
    kind: HealthObservationKind,
    aggregation: HealthMetricAggregation,
    unit: HealthMetricUnit,
    latestSample: HealthMetricPoint?,
    dailyPoints: [HealthMetricPoint],
    intradayPoints: [HealthMetricPoint]
  ) {
    self.kind = kind
    self.aggregation = aggregation
    self.unit = unit
    self.latestSample = latestSample
    self.dailyPoints = dailyPoints
    self.intradayPoints = intradayPoints
  }
}

/// One bounded dashboard snapshot. It avoids loading any individual health observation payload.
public struct HealthArchiveDashboard: Equatable, Sendable {
  /// Monotonic local archive revision. It advances only when the committed factual archive
  /// changes, so presentation caches can distinguish a harmless re-entry from new health data.
  public let archiveRevision: UInt64
  public let summary: HealthArchiveSummary
  public let coverage: [HealthObservationCoverage]
  public let recentSyncs: [HealthSyncReceipt]
  public let dailyCounts: [HealthArchiveDayCount]
  public let metricSeries: [HealthMetricSeries]

  public init(
    archiveRevision: UInt64 = 0,
    summary: HealthArchiveSummary,
    coverage: [HealthObservationCoverage],
    recentSyncs: [HealthSyncReceipt],
    dailyCounts: [HealthArchiveDayCount],
    metricSeries: [HealthMetricSeries] = []
  ) {
    self.archiveRevision = archiveRevision
    self.summary = summary
    self.coverage = coverage
    self.recentSyncs = recentSyncs
    self.dailyCounts = dailyCounts
    self.metricSeries = metricSeries
  }
}

public enum HealthArchiveApplyResult: Equatable, Sendable { case applied, alreadyApplied }

public protocol HealthArchiveRepository: Sendable {
  func apply(_ batch: HealthArchiveBatch) async throws -> HealthArchiveApplyResult
  func observations(matching query: HealthArchiveQuery) async throws -> [HealthObservation]
  func coverage() async throws -> [HealthObservationCoverage]
  func dashboard(matching query: HealthArchiveStatisticsQuery) async throws
    -> HealthArchiveDashboard
  func delete(_ request: HealthArchiveDeletionRequest) async throws -> HealthArchiveDeletionResult
  func export(matching query: HealthArchiveQuery, exportedAt: Date) async throws
    -> HealthArchiveExport
}
