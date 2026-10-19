import DaydayCore
import Foundation
import Testing

@testable import DaydayStorage

@Suite("SQLite health archive repository", .serialized)
struct SQLiteHealthArchiveRepositoryTests {
  @Test("Every collected nonclinical HealthKit kind has an explicit dashboard projection")
  func completeMetricCatalog() {
    #expect(
      SQLiteHealthArchiveRepository.supportedMetricKinds == Set(HealthObservationKind.allCases))
  }

  @Test("A batch is atomic, idempotent, and produces factual coverage")
  func storesAndReplaysBatch() async throws {
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory)
    let sourceID = uuid(1)
    let first = try observation(
      sourceID: sourceID, recordID: uuid(2), kind: .stepCount, endsAt: 100)
    let second = try observation(
      sourceID: sourceID, recordID: uuid(3), kind: .stepCount, endsAt: 200)
    let batch = try HealthArchiveBatch(
      batchID: uuid(4), sourceInstallationID: sourceID, createdAt: date(300),
      observations: [first, second], tombstones: []
    )

    #expect(try await repository.apply(batch) == .applied)
    #expect(try await repository.apply(batch) == .alreadyApplied)
    #expect(
      try await repository.observations(matching: HealthArchiveQuery()).map(\.key) == [
        second.key, first.key,
      ])
    #expect(
      try await repository.coverage() == [
        HealthObservationCoverage(
          kind: .stepCount, observationCount: 2, latestEndedAt: second.endedAt)
      ])
    #expect(try await repository.schemaVersion() == 6)
  }

  @Test("Tombstones remove facts and a reused batch ID must be identical")
  func tombstonesAndConflictingBatchReuse() async throws {
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory)
    let sourceID = uuid(10)
    let record = try observation(
      sourceID: sourceID, recordID: uuid(11), kind: .bodyMass, endsAt: 100)
    let first = try HealthArchiveBatch(
      batchID: uuid(12), sourceInstallationID: sourceID, createdAt: date(101),
      observations: [record], tombstones: []
    )
    _ = try await repository.apply(first)
    let removal = try HealthArchiveBatch(
      batchID: uuid(13), sourceInstallationID: sourceID, createdAt: date(102), observations: [],
      tombstones: [
        try HealthObservationTombstone(key: record.key, kind: .bodyMass, deletedAt: date(102))
      ]
    )
    #expect(try await repository.apply(removal) == .applied)
    #expect(try await repository.observations(matching: HealthArchiveQuery()).isEmpty)

    let conflicting = try HealthArchiveBatch(
      batchID: first.batchID, sourceInstallationID: sourceID, createdAt: date(999),
      observations: [], tombstones: []
    )
    await #expect(throws: HealthArchiveStoreError.conflictingBatchReuse) {
      _ = try await repository.apply(conflicting)
    }
  }

  @Test("Type and date queries are bounded")
  func queryFilters() async throws {
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory)
    let sourceID = uuid(20)
    let early = try observation(
      sourceID: sourceID, recordID: uuid(21), kind: .heartRate, endsAt: 100)
    let late = try observation(sourceID: sourceID, recordID: uuid(22), kind: .bodyMass, endsAt: 200)
    let batch = try HealthArchiveBatch(
      sourceInstallationID: sourceID, createdAt: date(201), observations: [early, late],
      tombstones: []
    )
    _ = try await repository.apply(batch)

    let query = try HealthArchiveQuery(
      kinds: [.heartRate], startsAtOrAfter: date(50), endsAtOrBefore: date(150))
    #expect(try await repository.observations(matching: query) == [early])
  }

  @Test("Dashboard statistics are complete without loading individual observations")
  func dashboardStatistics() async throws {
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory)
    let sourceID = uuid(23)
    let steps = try observation(
      sourceID: sourceID, recordID: uuid(24), kind: .stepCount, endsAt: 100)
    let heart = try observation(
      sourceID: sourceID, recordID: uuid(25), kind: .heartRate, endsAt: 200)
    let batch = try HealthArchiveBatch(
      batchID: uuid(26), sourceInstallationID: sourceID, createdAt: date(201),
      observations: [steps, heart], tombstones: []
    )
    _ = try await repository.apply(batch)

    let dashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(
        kinds: [.stepCount], startsAt: date(0), endsAt: date(300), recentSyncLimit: 5
      ))
    #expect(dashboard.summary.observationCount == 2)
    #expect(dashboard.summary.coveredKindCount == 2)
    #expect(dashboard.summary.sourceInstallationCount == 1)
    #expect(dashboard.summary.receivedBatchCount == 1)
    #expect(dashboard.summary.earliestEndedAt == steps.endedAt)
    #expect(dashboard.summary.latestEndedAt == heart.endedAt)
    #expect(dashboard.coverage.map(\.kind) == [.stepCount])
    #expect(dashboard.recentSyncs.count == 1)
    #expect(dashboard.recentSyncs.first?.batchID == batch.batchID)
    #expect(dashboard.recentSyncs.first?.observationCount == 2)
    #expect(dashboard.recentSyncs.first?.tombstoneCount == 0)
    #expect(dashboard.dailyCounts.map(\.observationCount) == [1])
    #expect(dashboard.archiveRevision == 1)
  }

  @Test("Dashboard projects heart rate, reconciled steps, and asleep duration as real values")
  func dashboardMetricSeriesUseHealthValues() async throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory, timeZone: utc)
    let watchID = uuid(70)
    let phoneID = uuid(71)
    let corosID = uuid(72)

    let watchFacts = [
      try observation(
        sourceID: watchID,
        recordID: uuid(73),
        kind: .heartRate,
        endsAt: 3_900,
        value: 60,
        unit: "count/min"
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(74),
        kind: .heartRate,
        endsAt: 4_200,
        value: 80,
        unit: "count/min"
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(75),
        kind: .stepCount,
        endsAt: 5_000,
        value: 1_000
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(76),
        kind: .stepCount,
        endsAt: 9_000,
        value: 500
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(77),
        kind: .sleepAnalysis,
        startedAt: 78_400,
        endsAt: 85_600,
        payload: .category(rawValue: 3)
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(78),
        kind: .sleepAnalysis,
        startedAt: 85_600,
        endsAt: 92_800,
        payload: .category(rawValue: 4)
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(79),
        kind: .sleepAnalysis,
        startedAt: 92_800,
        endsAt: 100_000,
        payload: .category(rawValue: 5)
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(80),
        kind: .sleepAnalysis,
        startedAt: 71_200,
        endsAt: 100_000,
        payload: .category(rawValue: 0)
      ),
      try observation(
        sourceID: watchID,
        recordID: uuid(81),
        kind: .sleepAnalysis,
        startedAt: 89_200,
        endsAt: 91_000,
        payload: .category(rawValue: 2)
      ),
    ]
    let phoneFacts = [
      try observation(
        sourceID: phoneID,
        recordID: uuid(82),
        kind: .stepCount,
        endsAt: 5_100,
        sourceName: "iPhone",
        bundleIdentifier: "com.apple.health.phone",
        value: 800
      ),
      try observation(
        sourceID: phoneID,
        recordID: uuid(83),
        kind: .stepCount,
        endsAt: 9_100,
        sourceName: "iPhone",
        bundleIdentifier: "com.apple.health.phone",
        value: 700
      ),
    ]
    let corosFacts = [
      try observation(
        sourceID: corosID,
        recordID: uuid(84),
        kind: .sleepAnalysis,
        startedAt: 73_100,
        endsAt: 100_100,
        sourceName: "COROS",
        bundleIdentifier: "com.coros.coros",
        payload: .category(rawValue: 1)
      )
    ]

    for (index, pair) in [(watchID, watchFacts), (phoneID, phoneFacts), (corosID, corosFacts)]
      .enumerated()
    {
      _ = try await repository.apply(
        HealthArchiveBatch(
          batchID: uuid(UInt8(90 + index)),
          sourceInstallationID: pair.0,
          createdAt: date(110_000 + Double(index)),
          observations: pair.1,
          tombstones: []
        ))
    }

    let dashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(
        startsAt: date(0),
        endsAt: date(172_799)
      ))
    await repository.waitForAllHealthBackfillsForTesting()
    let rollupDashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(
        startsAt: date(0),
        endsAt: date(172_799)
      ))
    #expect(rollupDashboard == dashboard)
    let metrics = Dictionary(uniqueKeysWithValues: dashboard.metricSeries.map { ($0.kind, $0) })

    let heartRate = try #require(metrics[.heartRate])
    #expect(heartRate.unit == .beatsPerMinute)
    #expect(heartRate.aggregation == .discreteAverage)
    #expect(heartRate.latestSample?.value == 80)
    #expect(heartRate.dailyPoints.count == 1)
    #expect(heartRate.dailyPoints.first?.value == 70)
    #expect(heartRate.dailyPoints.first?.minimum == 60)
    #expect(heartRate.dailyPoints.first?.maximum == 80)
    #expect(heartRate.intradayPoints.map(\.value) == [60, 80])
    #expect(
      heartRate.intradayPoints.map { $0.endedAt.timeIntervalSince($0.startedAt) }
        == [300, 300]
    )

    let steps = try #require(metrics[.stepCount])
    #expect(steps.unit == .count)
    #expect(steps.aggregation == .cumulativeSum)
    #expect(steps.dailyPoints.count == 1)
    #expect(steps.dailyPoints.first?.value == 1_700)
    #expect(steps.intradayPoints.map(\.value) == [1_000, 700])
    #expect(
      steps.intradayPoints.map { $0.endedAt.timeIntervalSince($0.startedAt) }
        == [900, 900]
    )

    let sleep = try #require(metrics[.sleepAnalysis])
    #expect(sleep.unit == .seconds)
    #expect(sleep.aggregation == .duration)
    #expect(sleep.dailyPoints.count == 1)
    #expect(sleep.dailyPoints.first?.value == 27_000)
  }

  @Test("Dashboard projects additional measured metrics with explicit units and aggregation")
  func dashboardProjectsExpandedMetricCatalog() async throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory, timeZone: utc)
    let watchID = uuid(111)
    let phoneID = uuid(112)
    let watchFacts = [
      try observation(
        sourceID: watchID, recordID: uuid(113), kind: .respiratoryRate,
        endsAt: 3_900, value: 12, unit: "count/min"),
      try observation(
        sourceID: watchID, recordID: uuid(114), kind: .respiratoryRate,
        endsAt: 4_200, value: 18, unit: "count/min"),
      try observation(
        sourceID: watchID, recordID: uuid(115), kind: .activeEnergyBurned,
        endsAt: 5_000, value: 100, unit: "kcal"),
      try observation(
        sourceID: watchID, recordID: uuid(116), kind: .activeEnergyBurned,
        endsAt: 5_100, value: 200, unit: "kcal"),
      try observation(
        sourceID: watchID, recordID: uuid(117), kind: .bodyMass,
        endsAt: 7_000, value: 70.5, unit: "kg"),
      try observation(
        sourceID: watchID, recordID: uuid(118), kind: .dietaryWater,
        endsAt: 8_000, value: 0.6, unit: "L"),
      try observation(
        sourceID: watchID, recordID: uuid(119), kind: .mindfulSession,
        startedAt: 9_000, endsAt: 9_600, payload: .category(rawValue: 0)),
      try observation(
        sourceID: watchID, recordID: uuid(120), kind: .workout,
        startedAt: 10_000, endsAt: 11_800,
        payload: .workout(activityType: 1, duration: 1_800, activeEnergyKilocalories: 120)),
      try observation(
        sourceID: watchID, recordID: uuid(124), kind: .height,
        endsAt: 12_000, value: 1.75, unit: "m"),
      try observation(
        sourceID: watchID, recordID: uuid(125), kind: .dietarySodium,
        endsAt: 13_000, value: 420, unit: "mg"),
      try observation(
        sourceID: watchID, recordID: uuid(126), kind: .appleStandHour,
        startedAt: 14_400, endsAt: 18_000, payload: .category(rawValue: 0)),
    ]
    let phoneFacts = [
      try observation(
        sourceID: phoneID, recordID: uuid(121), kind: .activeEnergyBurned,
        endsAt: 5_200, sourceName: "iPhone",
        bundleIdentifier: "com.apple.health.phone", value: 250, unit: "kcal"),
      try observation(
        sourceID: phoneID, recordID: uuid(127), kind: .appleStandHour,
        startedAt: 14_400, endsAt: 18_000, sourceName: "iPhone",
        bundleIdentifier: "com.apple.health.phone", payload: .category(rawValue: 0)),
    ]

    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(122), sourceInstallationID: watchID, createdAt: date(20_000),
        observations: watchFacts, tombstones: []))
    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(123), sourceInstallationID: phoneID, createdAt: date(20_001),
        observations: phoneFacts, tombstones: []))

    let dashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(startsAt: date(0), endsAt: date(86_399)))
    await repository.waitForAllHealthBackfillsForTesting()
    let rollupDashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(startsAt: date(0), endsAt: date(86_399)))
    #expect(rollupDashboard == dashboard)
    let metrics = Dictionary(uniqueKeysWithValues: dashboard.metricSeries.map { ($0.kind, $0) })

    let breathing = try #require(metrics[.respiratoryRate])
    #expect(breathing.unit == .countPerMinute)
    #expect(breathing.dailyPoints.first?.value == 15)
    #expect(breathing.latestSample?.value == 18)

    let energy = try #require(metrics[.activeEnergyBurned])
    #expect(energy.unit == .kilocalories)
    #expect(energy.dailyPoints.first?.value == 300)

    #expect(metrics[.bodyMass]?.unit == .kilograms)
    #expect(metrics[.bodyMass]?.latestSample?.value == 70.5)
    #expect(metrics[.dietaryWater]?.unit == .liters)
    #expect(metrics[.dietaryWater]?.dailyPoints.first?.value == 0.6)
    #expect(metrics[.mindfulSession]?.dailyPoints.first?.value == 600)
    #expect(metrics[.workout]?.dailyPoints.first?.value == 1_800)
    #expect(metrics[.height]?.unit == .meters)
    #expect(metrics[.height]?.latestSample?.value == 1.75)
    #expect(metrics[.dietarySodium]?.unit == .milligrams)
    #expect(metrics[.dietarySodium]?.dailyPoints.first?.value == 420)
    #expect(metrics[.appleStandHour]?.dailyPoints.first?.value == 1)
  }

  @Test("Sleep sessionization retains stages ending before the requested day boundary")
  func sleepSessionUsesFiniteLookbackBeforeRangeStart() async throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory, timeZone: utc)
    let sourceID = uuid(130)
    let stages = [
      try observation(
        sourceID: sourceID, recordID: uuid(131), kind: .sleepAnalysis,
        startedAt: 79_200, endsAt: 82_800, payload: .category(rawValue: 3)),
      try observation(
        sourceID: sourceID, recordID: uuid(132), kind: .sleepAnalysis,
        startedAt: 82_800, endsAt: 90_000, payload: .category(rawValue: 4)),
    ]
    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(133), sourceInstallationID: sourceID, createdAt: date(90_001),
        observations: stages, tombstones: []))

    let dashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(startsAt: date(86_400), endsAt: date(172_799)))
    let sleep = try #require(dashboard.metricSeries.first { $0.kind == .sleepAnalysis })
    #expect(sleep.dailyPoints.map(\.value) == [10_800])
    #expect(sleep.dailyPoints.map(\.contributingSampleCount) == [2])
  }

  @Test("Archive revisions and daily rollups follow updates and tombstones atomically")
  func revisionsAndRollupsTrackMutations() async throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory, timeZone: utc)
    let sourceID = uuid(27)
    let key = uuid(28)
    let first = try observation(sourceID: sourceID, recordID: key, kind: .stepCount, endsAt: 3_600)
    let firstBatch = try HealthArchiveBatch(
      batchID: uuid(29),
      sourceInstallationID: sourceID,
      createdAt: date(4_000),
      observations: [first],
      tombstones: []
    )
    #expect(try await repository.apply(firstBatch) == .applied)
    #expect(try await repository.apply(firstBatch) == .alreadyApplied)

    let fullRange = try HealthArchiveStatisticsQuery(
      startsAt: date(0),
      endsAt: date(172_799)
    )
    let initial = try await repository.dashboard(matching: fullRange)
    #expect(initial.archiveRevision == 1)
    #expect(initial.dailyCounts.map(\.observationCount) == [1])
    #expect(initial.coverage.map(\.kind) == [.stepCount])

    let moved = try observation(
      sourceID: sourceID,
      recordID: key,
      kind: .heartRate,
      endsAt: 90_000
    )
    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(35),
        sourceInstallationID: sourceID,
        createdAt: date(91_000),
        observations: [moved],
        tombstones: []
      ))
    let updated = try await repository.dashboard(matching: fullRange)
    #expect(updated.archiveRevision == 2)
    #expect(updated.summary.observationCount == 1)
    #expect(updated.coverage.map(\.kind) == [.heartRate])
    #expect(updated.dailyCounts.map(\.logicalDate) == ["2001-01-02"])

    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(36),
        sourceInstallationID: sourceID,
        createdAt: date(92_000),
        observations: [],
        tombstones: [
          try HealthObservationTombstone(
            key: moved.key,
            kind: moved.kind,
            deletedAt: date(92_000)
          )
        ]
      ))
    let removed = try await repository.dashboard(matching: fullRange)
    #expect(removed.archiveRevision == 3)
    #expect(removed.summary.observationCount == 0)
    #expect(removed.coverage.isEmpty)
    #expect(removed.dailyCounts.isEmpty)
  }

  @Test("Metric daily rollups update only factual occupied days and follow tombstones")
  func metricDailyRollupsTrackMutationsWithoutFillingMissingDays() async throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory, timeZone: utc)
    let sourceID = uuid(140)
    let key = uuid(141)
    let first = try observation(
      sourceID: sourceID,
      recordID: key,
      kind: .heartRate,
      endsAt: 3_600,
      value: 60,
      unit: "count/min"
    )
    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(142), sourceInstallationID: sourceID, createdAt: date(4_000),
        observations: [first], tombstones: []))
    let range = try HealthArchiveStatisticsQuery(startsAt: date(0), endsAt: date(172_799))
    let initial = try await repository.dashboard(matching: range)
    let initialHeartRate = try #require(initial.metricSeries.first { $0.kind == .heartRate })
    #expect(initialHeartRate.dailyPoints.map(\.value) == [60])
    #expect(initialHeartRate.dailyPoints.count == 1)
    await repository.waitForAllHealthBackfillsForTesting()

    let updated = try observation(
      sourceID: sourceID,
      recordID: key,
      kind: .heartRate,
      endsAt: 3_600,
      value: 84,
      unit: "count/min"
    )
    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(143), sourceInstallationID: sourceID, createdAt: date(5_000),
        observations: [updated], tombstones: []))
    let refreshed = try await repository.dashboard(matching: range)
    let refreshedHeartRate = try #require(refreshed.metricSeries.first { $0.kind == .heartRate })
    #expect(refreshedHeartRate.dailyPoints.map(\.value) == [84])

    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(144), sourceInstallationID: sourceID, createdAt: date(6_000),
        observations: [],
        tombstones: [
          try HealthObservationTombstone(
            key: updated.key, kind: updated.kind, deletedAt: date(6_000))
        ]))
    let removed = try await repository.dashboard(matching: range)
    #expect(removed.metricSeries.allSatisfy { $0.kind != .heartRate })
  }

  @Test("Apply and delete during backfill restart projections at the newest revision")
  func mutationsDuringBackfillNeverPublishStaleProjection() async throws {
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory, timeZone: utc)
    let sourceID = uuid(160)
    let first = try observation(
      sourceID: sourceID, recordID: uuid(161), kind: .heartRate,
      endsAt: 3_600, value: 60, unit: "count/min")
    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(162), sourceInstallationID: sourceID, createdAt: date(3_601),
        observations: [first], tombstones: []))
    let query = try HealthArchiveStatisticsQuery(startsAt: date(0), endsAt: date(172_799))
    _ = try await repository.dashboard(matching: query)
    #expect((await repository.metricRollupBackfillStatusForTesting()).isRunning)

    let second = try observation(
      sourceID: sourceID, recordID: uuid(163), kind: .heartRate,
      endsAt: 90_000, value: 80, unit: "count/min")
    _ = try await repository.apply(
      HealthArchiveBatch(
        batchID: uuid(164), sourceInstallationID: sourceID, createdAt: date(90_001),
        observations: [second], tombstones: []))
    _ = try await repository.delete(
      HealthArchiveDeletionRequest(
        kinds: [.heartRate], startsAtOrAfter: date(0), endsAtOrBefore: date(5_000)))
    _ = try await repository.dashboard(matching: query)
    await repository.waitForAllHealthBackfillsForTesting()

    let final = try await repository.dashboard(matching: query)
    #expect(final.archiveRevision == 3)
    #expect(final.summary.observationCount == 1)
    let heart = try #require(final.metricSeries.first { $0.kind == .heartRate })
    #expect(heart.dailyPoints.map(\.value) == [80])
  }

  @Test("Cancelled partial backfill resumes deterministically after repository reopen")
  func cancelledBackfillResumesAfterReopen() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-health-backfill-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = SQLiteDatabaseLocation.file(directory.appendingPathComponent("health.sqlite"))
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let query = try HealthArchiveStatisticsQuery(startsAt: date(0), endsAt: date(172_799))
    let expected: HealthArchiveDashboard
    do {
      let repository = try SQLiteHealthArchiveRepository(location: location, timeZone: utc)
      let sourceID = uuid(170)
      let facts = [
        try observation(
          sourceID: sourceID, recordID: uuid(171), kind: .heartRate,
          endsAt: 3_600, value: 64, unit: "count/min"),
        try observation(
          sourceID: sourceID, recordID: uuid(172), kind: .stepCount,
          endsAt: 7_200, value: 2_000),
      ]
      _ = try await repository.apply(
        HealthArchiveBatch(
          batchID: uuid(173), sourceInstallationID: sourceID, createdAt: date(7_201),
          observations: facts, tombstones: []))
      expected = try await repository.dashboard(matching: query)
      await repository.cancelHealthBackfillsForTesting()
    }

    let reopened = try SQLiteHealthArchiveRepository(location: location, timeZone: utc)
    let fallback = try await reopened.dashboard(matching: query)
    #expect(fallback == expected)
    await reopened.waitForAllHealthBackfillsForTesting()
    let completed = try await reopened.dashboard(matching: query)
    #expect(completed == expected)
  }

  @Test("Local-day aggregation precomputes daylight-saving offsets")
  func localDayOffsetsFollowTimeZoneTransitions() throws {
    let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let start = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 3, day: 1
        )))
    let end = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 12, day: 1
        )))

    let intervals = SQLiteHealthArchiveRepository.localDayOffsetIntervals(
      startsAt: start,
      endsAt: end,
      timeZone: timeZone
    )

    #expect(intervals.count == 3)
    #expect(intervals.map(\.secondsFromGMT) == [-28_800, -25_200, -28_800])
    #expect(intervals[0].upperBound != nil)
    #expect(intervals[1].upperBound != nil)
    #expect(intervals[2].upperBound == nil)
  }

  @Test("Extrema repair uses bounded ordered indexes instead of aggregate scans")
  func extremaRepairQueryPlansAreIndexed() throws {
    let database = try SQLiteDatabase(location: .inMemory)
    defer { database.close() }
    try database.execute(
      """
      CREATE TABLE health_archive_observations (
        source_installation_id TEXT NOT NULL, healthkit_uuid TEXT NOT NULL,
        kind TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL NOT NULL,
        received_at REAL NOT NULL, payload TEXT NOT NULL,
        PRIMARY KEY (source_installation_id, healthkit_uuid)
      ) STRICT;
      CREATE INDEX health_archive_observations_query
      ON health_archive_observations(kind, ended_at DESC, healthkit_uuid ASC);
      CREATE INDEX health_archive_observations_ended_at
      ON health_archive_observations(ended_at DESC, kind ASC);
      """)
    let global = try database.prepare(
      "EXPLAIN QUERY PLAN SELECT ended_at FROM health_archive_observations ORDER BY ended_at ASC LIMIT 1"
    )
    #expect(try global.stepRow())
    #expect(try global.requiredText(at: 3, column: "detail").contains("ended_at"))
    let kind = try database.prepare(
      "EXPLAIN QUERY PLAN SELECT ended_at FROM health_archive_observations WHERE kind = 'heartRate' ORDER BY ended_at DESC LIMIT 1"
    )
    #expect(try kind.stepRow())
    #expect(try kind.requiredText(at: 3, column: "detail").contains("observations_query"))
  }

  @Test("A local deletion is bounded, never asks HealthKit to delete, and suppresses a retry")
  func localDeletionSuppressesOnlyTheRemovedCopy() async throws {
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory)
    let sourceID = uuid(30)
    let heartRate = try observation(
      sourceID: sourceID, recordID: uuid(31), kind: .heartRate, endsAt: 100)
    let bodyMass = try observation(
      sourceID: sourceID, recordID: uuid(32), kind: .bodyMass, endsAt: 100)
    let original = try HealthArchiveBatch(
      batchID: uuid(33), sourceInstallationID: sourceID, createdAt: date(101),
      observations: [heartRate, bodyMass], tombstones: []
    )
    _ = try await repository.apply(original)
    let dashboardQuery = try HealthArchiveStatisticsQuery(
      startsAt: date(0), endsAt: date(200)
    )
    _ = try await repository.dashboard(matching: dashboardQuery)

    let deletion = try HealthArchiveDeletionRequest(
      kinds: [.heartRate], startsAtOrAfter: date(50), endsAtOrBefore: date(150)
    )
    #expect(
      try await repository.delete(deletion)
        == HealthArchiveDeletionResult(removedObservationCount: 1))
    #expect(try await repository.observations(matching: HealthArchiveQuery()) == [bodyMass])
    let afterDeletion = try await repository.dashboard(matching: dashboardQuery)
    #expect(afterDeletion.archiveRevision == 2)
    #expect(afterDeletion.summary.observationCount == 1)
    #expect(afterDeletion.coverage.map(\.kind) == [.bodyMass])
    #expect(afterDeletion.dailyCounts.map(\.observationCount) == [1])

    let retryWithNewBatchID = try HealthArchiveBatch(
      batchID: uuid(34), sourceInstallationID: sourceID, createdAt: date(102),
      observations: [heartRate], tombstones: []
    )
    _ = try await repository.apply(retryWithNewBatchID)
    #expect(try await repository.observations(matching: HealthArchiveQuery()) == [bodyMass])
    let afterSuppressedRetry = try await repository.dashboard(matching: dashboardQuery)
    #expect(afterSuppressedRetry.archiveRevision == 3)
    #expect(afterSuppressedRetry.summary.observationCount == 1)
  }

  @Test("Export is a complete factual snapshot for the selected range")
  func exportsAllSelectedFacts() async throws {
    let repository = try SQLiteHealthArchiveRepository(location: .inMemory)
    let sourceID = uuid(40)
    let first = try observation(
      sourceID: sourceID, recordID: uuid(41), kind: .heartRate, endsAt: 100)
    let second = try observation(
      sourceID: sourceID, recordID: uuid(42), kind: .heartRate, endsAt: 200)
    _ = try await repository.apply(
      HealthArchiveBatch(
        sourceInstallationID: sourceID, createdAt: date(201), observations: [first, second],
        tombstones: []
      ))

    let exported = try await repository.export(
      matching: try HealthArchiveQuery(
        kinds: [.heartRate], startsAtOrAfter: date(50), endsAtOrBefore: date(250)),
      exportedAt: date(300)
    )
    #expect(exported.format == HealthArchiveExport.format)
    #expect(exported.exportedAt == date(300))
    #expect(exported.observations == [second, first])
  }

  @Test("A v1 archive migrates without losing its stored facts")
  func migratesV1Archive() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-health-archive-v1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = SQLiteDatabaseLocation.file(directory.appendingPathComponent("health.sqlite"))
    let sourceID = uuid(50)
    let fact = try observation(
      sourceID: sourceID, recordID: uuid(51), kind: .dietaryWater, endsAt: 100)
    let first = try SQLiteHealthArchiveRepository(location: location)
    _ = try await first.apply(
      HealthArchiveBatch(
        sourceInstallationID: sourceID, createdAt: date(101), observations: [fact], tombstones: []
      ))

    let database = try SQLiteDatabase(location: location)
    try database.execute(
      """
      DROP INDEX health_archive_observations_ended_at;
      DROP INDEX health_archive_observations_source;
      DROP INDEX health_archive_batches_received_at;
      DROP TABLE health_archive_metric_rollup_states;
      DROP TABLE health_archive_metric_daily_rollups;
      DROP TABLE health_archive_daily_rollup_build_states;
      DROP TABLE health_archive_rollup_states;
      DROP TABLE health_archive_daily_rollups;
      DROP TABLE health_archive_source_totals;
      DROP TABLE health_archive_kind_totals;
      DROP TABLE health_archive_statistics_state;
      ALTER TABLE health_archive_batches RENAME TO health_archive_batches_v3;
      CREATE TABLE health_archive_batches (
        source_installation_id TEXT NOT NULL,
        batch_id TEXT NOT NULL,
        created_at REAL NOT NULL,
        payload TEXT NOT NULL,
        PRIMARY KEY (source_installation_id, batch_id)
      ) STRICT;
      INSERT INTO health_archive_batches(source_installation_id, batch_id, created_at, payload)
      SELECT source_installation_id, batch_id, created_at, payload FROM health_archive_batches_v3;
      DROP TABLE health_archive_batches_v3;
      DROP TABLE health_archive_local_suppressions;
      DELETE FROM health_archive_schema_migrations WHERE version IN (2, 3, 4, 5, 6);
      UPDATE health_archive_schema_metadata
      SET schema_version = 1,
          schema_fingerprint = '\(SQLiteHealthArchiveRepository.legacyV1SchemaFingerprint)'
      WHERE singleton = 1;
      """)
    database.close()

    let migrated = try SQLiteHealthArchiveRepository(location: location)
    #expect(try await migrated.schemaVersion() == 6)
    #expect(try await migrated.observations(matching: HealthArchiveQuery()) == [fact])
    let dashboard = try await migrated.dashboard(
      matching: HealthArchiveStatisticsQuery(
        startsAt: date(0), endsAt: date(200)
      ))
    #expect(dashboard.summary.observationCount == 1)
    #expect(dashboard.recentSyncs.first?.observationCount == 1)
  }

  @Test("A v4 archive opens without eagerly rebuilding metric payload rollups")
  func migratesV4WithoutBlockingPayloadBackfill() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-health-archive-v4-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = SQLiteDatabaseLocation.file(directory.appendingPathComponent("health.sqlite"))
    let sourceID = uuid(150)
    let fact = try observation(
      sourceID: sourceID,
      recordID: uuid(151),
      kind: .heartRate,
      endsAt: 3_600,
      value: 72,
      unit: "count/min"
    )
    do {
      let current = try SQLiteHealthArchiveRepository(location: location)
      _ = try await current.apply(
        HealthArchiveBatch(
          batchID: uuid(152), sourceInstallationID: sourceID, createdAt: date(3_601),
          observations: [fact], tombstones: []))
    }

    let oldDatabase = try SQLiteDatabase(location: location)
    try oldDatabase.execute(
      """
      DROP INDEX health_archive_metric_daily_query;
      DROP TABLE health_archive_metric_rollup_states;
      DROP TABLE health_archive_metric_daily_rollups;
      DROP TABLE health_archive_daily_rollup_build_states;
      DELETE FROM health_archive_schema_migrations WHERE version IN (5, 6);
      UPDATE health_archive_schema_metadata
      SET schema_version = 4,
          schema_fingerprint = '\(SQLiteHealthArchiveRepository.legacyV4SchemaFingerprint)'
      WHERE singleton = 1;
      """)
    oldDatabase.close()

    let migrated = try SQLiteHealthArchiveRepository(location: location)
    #expect(try await migrated.schemaVersion() == 6)
    let beforeDashboard = try SQLiteDatabase(location: location)
    let emptyRollup = try beforeDashboard.prepare(
      "SELECT COUNT(*) FROM health_archive_metric_daily_rollups")
    #expect(try emptyRollup.stepRow())
    #expect(try emptyRollup.requiredInt64(at: 0, column: "count") == 0)
    beforeDashboard.close()

    let dashboard = try await migrated.dashboard(
      matching: HealthArchiveStatisticsQuery(startsAt: date(0), endsAt: date(172_799)))
    #expect(
      dashboard.metricSeries.first { $0.kind == .heartRate }?.dailyPoints.map(\.value) == [72])
    let firstStatus = await migrated.metricRollupBackfillStatusForTesting()
    #expect(firstStatus.isRunning)
    #expect(firstStatus.launchCount == 1)

    _ = try await migrated.dashboard(
      matching: HealthArchiveStatisticsQuery(startsAt: date(0), endsAt: date(172_799)))
    let repeatedStatus = await migrated.metricRollupBackfillStatusForTesting()
    #expect(repeatedStatus.launchCount == 1)

    await migrated.waitForAllHealthBackfillsForTesting()
    let completedStatus = await migrated.metricRollupBackfillStatusForTesting()
    #expect(!completedStatus.isRunning)
    let completedDatabase = try SQLiteDatabase(location: location)
    let completedRollup = try completedDatabase.prepare(
      "SELECT COUNT(*) FROM health_archive_metric_daily_rollups")
    #expect(try completedRollup.stepRow())
    #expect(try completedRollup.requiredInt64(at: 0, column: "count") == 1)
    let completedState = try completedDatabase.prepare(
      """
      SELECT archive_revision, target_revision, next_definition_index
      FROM health_archive_metric_rollup_states
      """)
    #expect(try completedState.stepRow())
    #expect(try completedState.requiredInt64(at: 0, column: "archive_revision") == 1)
    #expect(try completedState.requiredInt64(at: 1, column: "target_revision") == 1)
    #expect(try completedState.requiredInt64(at: 2, column: "next_definition_index") == 51)
    completedDatabase.close()
  }

  @Test("A deployed v5 archive advances without changing health facts")
  func migratesDeployedV5SchemaDriftToV6() async throws {
    #expect(
      SQLiteHealthArchiveRepository.legacyV5SchemaFingerprint
        == "fnv1a64-97cbcf6eb693e058")
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-health-archive-v5-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = SQLiteDatabaseLocation.file(directory.appendingPathComponent("health.sqlite"))
    let sourceID = uuid(160)
    let fact = try observation(
      sourceID: sourceID, recordID: uuid(161), kind: .stepCount, endsAt: 7_200,
      value: 1_234, unit: "count")
    do {
      let current = try SQLiteHealthArchiveRepository(location: location)
      _ = try await current.apply(
        HealthArchiveBatch(
          batchID: uuid(162), sourceInstallationID: sourceID, createdAt: date(7_201),
          observations: [fact], tombstones: []))
    }

    let oldDatabase = try SQLiteDatabase(location: location)
    try oldDatabase.execute(
      """
      DROP TABLE health_archive_daily_rollup_build_states;
      DELETE FROM health_archive_schema_migrations WHERE version = 6;
      UPDATE health_archive_schema_metadata
      SET schema_version = 5,
          schema_fingerprint = '\(SQLiteHealthArchiveRepository.legacyV5SchemaFingerprint)'
      WHERE singleton = 1;
      """)
    oldDatabase.close()

    let migrated = try SQLiteHealthArchiveRepository(location: location)
    #expect(try await migrated.schemaVersion() == 6)
    #expect(try await migrated.observations(matching: HealthArchiveQuery()) == [fact])
    let migratedDatabase = try SQLiteDatabase(location: location)
    let progressTable = try migratedDatabase.prepare(
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'health_archive_daily_rollup_build_states'"
    )
    #expect(try progressTable.stepRow())
    #expect(try progressTable.requiredInt64(at: 0, column: "count") == 1)
    let migrations = try migratedDatabase.prepare(
      "SELECT GROUP_CONCAT(version, ',') FROM health_archive_schema_migrations ORDER BY version"
    )
    #expect(try migrations.stepRow())
    #expect(try migrations.requiredText(at: 0, column: "versions") == "1,2,3,4,5,6")
    migratedDatabase.close()
  }

  @Test("Dashboard remains bounded over two hundred thousand archived rows")
  func dashboardAtPersonalArchiveScale() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "dayday-health-dashboard-scale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = SQLiteDatabaseLocation.file(directory.appendingPathComponent("health.sqlite"))
    _ = try SQLiteHealthArchiveRepository(location: location)
    let database = try SQLiteDatabase(location: location)
    try database.execute(
      """
      WITH RECURSIVE rows(value) AS (
        VALUES(1)
        UNION ALL
        SELECT value + 1 FROM rows WHERE value < 200000
      )
      INSERT INTO health_archive_observations(
        source_installation_id, healthkit_uuid, kind, started_at, ended_at, received_at, payload
      )
      SELECT '00000000-0000-0000-0000-000000000001', printf('record-%06d', value),
             'heartRate', value - 10, value, value,
             '{"payload":{"kind":"quantity","unit":"count/min","value":72},"source":{"bundleIdentifier":"com.apple.health.watch"}}'
      FROM rows;
      DROP INDEX health_archive_observations_source;
      DROP TABLE health_archive_metric_rollup_states;
      DROP TABLE health_archive_metric_daily_rollups;
      DROP TABLE health_archive_daily_rollup_build_states;
      DROP TABLE health_archive_rollup_states;
      DROP TABLE health_archive_daily_rollups;
      DROP TABLE health_archive_source_totals;
      DROP TABLE health_archive_kind_totals;
      DROP TABLE health_archive_statistics_state;
      DELETE FROM health_archive_schema_migrations WHERE version IN (4, 5, 6);
      UPDATE health_archive_schema_metadata
      SET schema_version = 3,
          schema_fingerprint = '\(SQLiteHealthArchiveRepository.legacyV3SchemaFingerprint)'
      WHERE singleton = 1;
      """)
    database.close()

    let utc = try #require(TimeZone(secondsFromGMT: 0))
    let clock = ContinuousClock()
    let started = clock.now
    let repository = try SQLiteHealthArchiveRepository(location: location, timeZone: utc)
    let dashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(
        startsAt: date(0), endsAt: date(200_001), recentSyncLimit: 5
      ))
    let elapsed = started.duration(to: clock.now)

    #expect(dashboard.summary.observationCount == 200_000)
    #expect(dashboard.summary.coveredKindCount == 1)
    #expect(dashboard.summary.sourceInstallationCount == 1)
    #expect(dashboard.coverage.reduce(0) { $0 + $1.observationCount } == 200_000)
    #expect(dashboard.archiveRevision == 1)
    // The full suite exercises several SQLite repositories concurrently. Keep this guard wide
    // enough for that contention while still rejecting an accidental payload-decoding scan.
    #expect(elapsed < .seconds(10))

    await repository.waitForAllHealthBackfillsForTesting()
    let warmStarted = clock.now
    let warmDashboard = try await repository.dashboard(
      matching: HealthArchiveStatisticsQuery(
        startsAt: date(0), endsAt: date(200_001), recentSyncLimit: 5
      ))
    let warmElapsed = warmStarted.duration(to: clock.now)
    #expect(warmDashboard == dashboard)
    #expect(warmElapsed < .seconds(1))
    await repository.cancelHealthBackfillsForTesting()
  }

  private func observation(
    sourceID: UUID,
    recordID: UUID,
    kind: HealthObservationKind,
    startedAt: TimeInterval? = nil,
    endsAt: TimeInterval,
    sourceName: String = "Apple Watch",
    bundleIdentifier: String = "com.apple.health.watch",
    value: Double = 72,
    unit: String = "count",
    payload: HealthObservationPayload? = nil
  ) throws -> HealthObservation {
    try HealthObservation(
      key: HealthObservationKey(sourceInstallationID: sourceID, healthKitUUID: recordID),
      kind: kind,
      startedAt: date(startedAt ?? endsAt - 10),
      endedAt: date(endsAt),
      source: try HealthObservationSource(
        name: sourceName, bundleIdentifier: bundleIdentifier),
      payload: try payload ?? HealthObservationPayload(quantityValue: value, unit: unit),
      receivedAt: date(endsAt + 1)
    )
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }
  private func uuid(_ seed: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, seed))
  }
}
