import DaydayCore
import Foundation

extension SQLiteHealthArchiveRepository {
  static let statisticsRollupIdentifier = "__dayday_statistics__"
  struct StatisticsState {
    let revision: UInt64
    let observationCount: Int
    let receivedBatchCount: Int
    let earliestEndedAt: Date?
    let latestEndedAt: Date?
    let latestBatchReceivedAt: Date?
  }

  struct StoredObservationIndex: Hashable {
    let sourceInstallationID: UUID
    let kind: HealthObservationKind
    let endedAt: Date
  }

  struct DailyRollupCell: Hashable {
    let logicalDate: String
    let kind: HealthObservationKind
  }

  struct ObservationInterval {
    let startsAt: Date
    let endsAt: Date
    let includesEnd: Bool
  }

  struct StatisticsRangePartition {
    let completeStartLogicalDate: String?
    let completeEndLogicalDate: String?
    let partialIntervals: [ObservationInterval]

    var hasCompleteDays: Bool {
      completeStartLogicalDate != nil && completeEndLogicalDate != nil
    }
  }

  static func coverage(
    matching query: HealthArchiveStatisticsQuery?,
    timeZone: TimeZone,
    usesDailyRollups: Bool = true,
    in database: SQLiteDatabase
  ) throws -> [HealthObservationCoverage] {
    guard let query else {
      let statement = try database.prepare(
        "SELECT kind, observation_count, latest_ended_at FROM health_archive_kind_totals ORDER BY kind ASC"
      )
      return try decodeCoverage(statement)
    }

    if !usesDailyRollups {
      return try decodeCoverage(
        partialCoverageStatement(
          query: query,
          interval: ObservationInterval(
            startsAt: query.startsAt, endsAt: query.endsAt, includesEnd: true),
          in: database
        ))
    }

    let partition = statisticsRangePartition(for: query, timeZone: timeZone)
    var aggregate: [HealthObservationKind: (count: Int, latest: Date?)] = [:]
    if partition.hasCompleteDays,
      let completeStart = partition.completeStartLogicalDate,
      let completeEnd = partition.completeEndLogicalDate
    {
      let kinds = query.kinds?.map(\.rawValue).sorted() ?? []
      let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
      let kindClause = kinds.isEmpty ? "" : " AND kind IN (\(placeholders))"
      let statement = try database.prepare(
        """
        SELECT kind, SUM(observation_count), MAX(latest_ended_at)
        FROM health_archive_daily_rollups
        WHERE time_zone_identifier = ? AND logical_date >= ? AND logical_date < ?\(kindClause)
        GROUP BY kind
        """)
      try statement.bind(timeZone.identifier, at: 1)
      try statement.bind(completeStart, at: 2)
      try statement.bind(completeEnd, at: 3)
      var index: Int32 = 4
      for kind in kinds {
        try statement.bind(kind, at: index)
        index += 1
      }
      try mergeCoverage(statement, into: &aggregate)
    }

    for interval in partition.partialIntervals {
      let statement = try partialCoverageStatement(
        query: query,
        interval: interval,
        in: database
      )
      try mergeCoverage(statement, into: &aggregate)
    }

    return aggregate.map { kind, value in
      HealthObservationCoverage(
        kind: kind,
        observationCount: value.count,
        latestEndedAt: value.latest
      )
    }.sorted { $0.kind.rawValue < $1.kind.rawValue }
  }

  private static func decodeCoverage(_ statement: SQLiteStatement) throws
    -> [HealthObservationCoverage]
  {
    var results: [HealthObservationCoverage] = []
    while try statement.stepRow() {
      guard
        let kind = HealthObservationKind(
          rawValue: try statement.requiredText(at: 0, column: "kind")),
        let count = Int(exactly: try statement.requiredInt64(at: 1, column: "count")),
        count >= 0
      else { throw HealthArchiveStoreError.invalidStoredPayload }
      results.append(
        HealthObservationCoverage(
          kind: kind,
          observationCount: count,
          latestEndedAt: Date(
            timeIntervalSinceReferenceDate: try statement.requiredDouble(at: 2, column: "latest")
          )
        ))
    }
    return results
  }

  private static func mergeCoverage(
    _ statement: SQLiteStatement,
    into aggregate: inout [HealthObservationKind: (count: Int, latest: Date?)]
  ) throws {
    for item in try decodeCoverage(statement) {
      let existing = aggregate[item.kind] ?? (0, nil)
      aggregate[item.kind] = (
        existing.count + item.observationCount,
        maxOptionalDate(existing.latest, item.latestEndedAt)
      )
    }
  }

  private static func partialCoverageStatement(
    query: HealthArchiveStatisticsQuery,
    interval: ObservationInterval,
    in database: SQLiteDatabase
  ) throws -> SQLiteStatement {
    let kinds = query.kinds?.map(\.rawValue).sorted() ?? []
    let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
    let kindClause = kinds.isEmpty ? "" : " AND kind IN (\(placeholders))"
    let endComparison = interval.includesEnd ? "<=" : "<"
    let statement = try database.prepare(
      """
      SELECT kind, COUNT(*), MAX(ended_at)
      FROM health_archive_observations
      WHERE ended_at >= ? AND ended_at \(endComparison) ?\(kindClause)
      GROUP BY kind
      """)
    try statement.bind(interval.startsAt.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(interval.endsAt.timeIntervalSinceReferenceDate, at: 2)
    var index: Int32 = 3
    for kind in kinds {
      try statement.bind(kind, at: index)
      index += 1
    }
    return statement
  }

  static func dailyCounts(
    matching query: HealthArchiveStatisticsQuery,
    timeZone: TimeZone,
    usesDailyRollups: Bool = true,
    in database: SQLiteDatabase
  ) throws -> [HealthArchiveDayCount] {
    if !usesDailyRollups {
      var aggregate: [String: Int] = [:]
      try mergeDailyCounts(
        partialDailyCountsStatement(
          query: query,
          interval: ObservationInterval(
            startsAt: query.startsAt, endsAt: query.endsAt, includesEnd: true),
          timeZone: timeZone,
          in: database
        ),
        into: &aggregate
      )
      return aggregate.map { logicalDate, count in
        HealthArchiveDayCount(logicalDate: logicalDate, observationCount: count)
      }.sorted { $0.logicalDate < $1.logicalDate }
    }
    let partition = statisticsRangePartition(for: query, timeZone: timeZone)
    var aggregate: [String: Int] = [:]
    if partition.hasCompleteDays,
      let completeStart = partition.completeStartLogicalDate,
      let completeEnd = partition.completeEndLogicalDate
    {
      let kinds = query.kinds?.map(\.rawValue).sorted() ?? []
      let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
      let kindClause = kinds.isEmpty ? "" : " AND kind IN (\(placeholders))"
      let statement = try database.prepare(
        """
        SELECT logical_date, SUM(observation_count)
        FROM health_archive_daily_rollups
        WHERE time_zone_identifier = ? AND logical_date >= ? AND logical_date < ?\(kindClause)
        GROUP BY logical_date
        ORDER BY logical_date ASC
        """)
      try statement.bind(timeZone.identifier, at: 1)
      try statement.bind(completeStart, at: 2)
      try statement.bind(completeEnd, at: 3)
      var index: Int32 = 4
      for kind in kinds {
        try statement.bind(kind, at: index)
        index += 1
      }
      try mergeDailyCounts(statement, into: &aggregate)
    }

    for interval in partition.partialIntervals {
      let statement = try partialDailyCountsStatement(
        query: query,
        interval: interval,
        timeZone: timeZone,
        in: database
      )
      try mergeDailyCounts(statement, into: &aggregate)
    }

    return aggregate.map { logicalDate, count in
      HealthArchiveDayCount(logicalDate: logicalDate, observationCount: count)
    }.sorted { $0.logicalDate < $1.logicalDate }
  }

  private enum MetricBucket {
    case day
    case fiveMinutes
    case quarterHour

    var interval: TimeInterval? {
      switch self {
      case .day: nil
      case .fiveMinutes: 5 * 60
      case .quarterHour: 15 * 60
      }
    }
  }

  private enum MetricProjection {
    case quantityAverage
    case reconciledQuantitySum
    case sleepDuration
    case categoryDuration
    case stoodHourCount
    case workoutDuration
  }

  private struct MetricDefinition {
    let kind: HealthObservationKind
    let rawUnit: String?
    let unit: HealthMetricUnit
    let aggregation: HealthMetricAggregation
    let projection: MetricProjection
  }

  /// Deliberately bounded dashboard catalog. Every entry names the exact unit emitted by the
  /// companion and an objective aggregation rule; a newly collected HealthKit type does not become
  /// a chart merely because records exist for it.
  private static let metricDefinitions: [MetricDefinition] = [
    .init(
      kind: .heartRate, rawUnit: "count/min", unit: .beatsPerMinute,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .restingHeartRate, rawUnit: "count/min", unit: .beatsPerMinute,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .heartRateVariabilitySDNN, rawUnit: "ms", unit: .milliseconds,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .respiratoryRate, rawUnit: "count/min", unit: .countPerMinute,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .oxygenSaturation, rawUnit: "%", unit: .percentage,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .walkingHeartRateAverage, rawUnit: "count/min", unit: .beatsPerMinute,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .vo2Max, rawUnit: "mL/min·kg", unit: .millilitersPerKilogramMinute,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .sleepingWristTemperature, rawUnit: "degC", unit: .degreesCelsius,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .stepCount, rawUnit: "count", unit: .count,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .distanceWalkingRunning, rawUnit: "m", unit: .meters,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .distanceCycling, rawUnit: "m", unit: .meters,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .activeEnergyBurned, rawUnit: "kcal", unit: .kilocalories,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .basalEnergyBurned, rawUnit: "kcal", unit: .kilocalories,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .appleExerciseTime, rawUnit: "min", unit: .minutes,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .timeInDaylight, rawUnit: "min", unit: .minutes,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .workout, rawUnit: nil, unit: .seconds,
      aggregation: .duration, projection: .workoutDuration),
    .init(
      kind: .bodyMass, rawUnit: "kg", unit: .kilograms,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .bodyMassIndex, rawUnit: "count", unit: .count,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .sleepAnalysis, rawUnit: nil, unit: .seconds,
      aggregation: .duration, projection: .sleepDuration),
    .init(
      kind: .mindfulSession, rawUnit: nil, unit: .seconds,
      aggregation: .duration, projection: .categoryDuration),
    .init(
      kind: .walkingSpeed, rawUnit: "m/s", unit: .metersPerSecond,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .dietaryWater, rawUnit: "L", unit: .liters,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .headphoneAudioExposure, rawUnit: "dBASPL", unit: .decibels,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .environmentalAudioExposure, rawUnit: "dBASPL", unit: .decibels,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .flightsClimbed, rawUnit: "count", unit: .count,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .appleStandTime, rawUnit: "min", unit: .minutes,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .appleMoveTime, rawUnit: "min", unit: .minutes,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .height, rawUnit: "m", unit: .meters,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .bodyFatPercentage, rawUnit: "%", unit: .percentage,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .leanBodyMass, rawUnit: "kg", unit: .kilograms,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .appleStandHour, rawUnit: nil, unit: .count,
      aggregation: .cumulativeSum, projection: .stoodHourCount),
    .init(
      kind: .walkingStepLength, rawUnit: "m", unit: .meters,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .walkingAsymmetryPercentage, rawUnit: "%", unit: .percentage,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .walkingDoubleSupportPercentage, rawUnit: "%", unit: .percentage,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .appleWalkingSteadiness, rawUnit: "count", unit: .count,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .stairAscentSpeed, rawUnit: "m/s", unit: .metersPerSecond,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .stairDescentSpeed, rawUnit: "m/s", unit: .metersPerSecond,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .sixMinuteWalkTestDistance, rawUnit: "m", unit: .meters,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .runningSpeed, rawUnit: "m/s", unit: .metersPerSecond,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .runningPower, rawUnit: "W", unit: .watts,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .runningStrideLength, rawUnit: "m", unit: .meters,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .runningGroundContactTime, rawUnit: "ms", unit: .milliseconds,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .runningVerticalOscillation, rawUnit: "m", unit: .meters,
      aggregation: .discreteAverage, projection: .quantityAverage),
    .init(
      kind: .dietaryEnergyConsumed, rawUnit: "kcal", unit: .kilocalories,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .dietaryProtein, rawUnit: "kg", unit: .kilograms,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .dietaryCarbohydrates, rawUnit: "kg", unit: .kilograms,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .dietaryFatTotal, rawUnit: "kg", unit: .kilograms,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .dietarySugar, rawUnit: "kg", unit: .kilograms,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .dietaryFiber, rawUnit: "kg", unit: .kilograms,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .dietarySodium, rawUnit: "mg", unit: .milligrams,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
    .init(
      kind: .dietaryCaffeine, rawUnit: "mg", unit: .milligrams,
      aggregation: .cumulativeSum, projection: .reconciledQuantitySum),
  ]

  static var supportedMetricKinds: Set<HealthObservationKind> {
    Set(metricDefinitions.map(\.kind))
  }

  /// Produces bounded, value-bearing series without materializing the underlying archive in
  /// Swift. Daily points cover the requested year. Recent intraday points cover at most seven
  /// local days: discrete quantities use five-minute averages, while cumulative quantities and
  /// durations use source-reconciled quarter-hour totals. Sleep keeps its session-aware daily
  /// reconciliation.
  static func metricSeries(
    matching query: HealthArchiveStatisticsQuery,
    timeZone: TimeZone,
    usesDailyRollups: Bool,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricSeries] {
    let supported = supportedMetricKinds
    let requested = query.kinds.map { supported.intersection($0) } ?? supported
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let todayStart =
      localDayBounds(logicalDate(for: query.endsAt, timeZone: timeZone), timeZone: timeZone)?
      .lowerBound ?? query.endsAt
    let recentDetailStart = max(
      calendar.date(
        byAdding: .day,
        value: -6,
        to: todayStart
      ) ?? todayStart,
      query.startsAt
    )

    return try metricDefinitions.compactMap { definition in
      guard requested.contains(definition.kind) else {
        return nil
      }
      let daily = try cachedDailyMetricPoints(
        definition: definition,
        query: query,
        timeZone: timeZone,
        usesDailyRollups: usesDailyRollups,
        in: database
      )
      guard !daily.isEmpty else { return nil }

      let intraday: [HealthMetricPoint]
      switch definition.projection {
      case .quantityAverage:
        guard let rawUnit = definition.rawUnit else {
          throw HealthArchiveStoreError.invalidStoredPayload
        }
        intraday = try quantityAveragePoints(
          kind: definition.kind,
          unit: rawUnit,
          startsAt: recentDetailStart,
          endsAt: query.endsAt,
          timeZone: timeZone,
          bucket: .fiveMinutes,
          in: database
        )
      case .reconciledQuantitySum:
        guard let rawUnit = definition.rawUnit else {
          throw HealthArchiveStoreError.invalidStoredPayload
        }
        intraday = try reconciledQuantityPoints(
          kind: definition.kind,
          unit: rawUnit,
          startsAt: recentDetailStart,
          endsAt: query.endsAt,
          timeZone: timeZone,
          bucket: .quarterHour,
          in: database
        )
      case .sleepDuration:
        intraday = []
      case .stoodHourCount:
        intraday = try reconciledStoodHourPoints(
          startsAt: recentDetailStart,
          endsAt: query.endsAt,
          timeZone: timeZone,
          bucket: .quarterHour,
          in: database
        )
      case .categoryDuration, .workoutDuration:
        let payloadKind = definition.projection == .categoryDuration ? "category" : "workout"
        let valueExpression =
          definition.projection == .categoryDuration
          ? "MAX(0, ended_at - started_at)"
          : "MAX(0, CAST(json_extract(payload, '$.payload.duration') AS REAL))"
        intraday = try reconciledDurationPoints(
          kind: definition.kind,
          payloadKind: payloadKind,
          valueExpression: valueExpression,
          startsAt: recentDetailStart,
          endsAt: query.endsAt,
          timeZone: timeZone,
          bucket: .quarterHour,
          in: database
        )
      }

      let latestSample: HealthMetricPoint?
      if definition.projection == .quantityAverage, let rawUnit = definition.rawUnit {
        latestSample = try latestQuantityPoint(
          kind: definition.kind,
          unit: rawUnit,
          startsAt: query.startsAt,
          endsAt: query.endsAt,
          in: database
        )
      } else {
        latestSample = daily.last
      }
      return HealthMetricSeries(
        kind: definition.kind,
        aggregation: definition.aggregation,
        unit: definition.unit,
        latestSample: latestSample,
        dailyPoints: daily,
        intradayPoints: intraday
      )
    }
  }

  private static func cachedDailyMetricPoints(
    definition: MetricDefinition,
    query: HealthArchiveStatisticsQuery,
    timeZone: TimeZone,
    usesDailyRollups: Bool,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricPoint] {
    // Sleep sessionization needs context across the query's day boundary. Its archive is sparse,
    // so preserve the exact range contract with one indexed bounded query instead of combining a
    // cached complete day with a context-free partial-day fragment.
    guard usesDailyRollups, definition.projection != .sleepDuration else {
      return try rawMetricPoints(
        definition: definition,
        startsAt: query.startsAt,
        endsAt: query.endsAt,
        timeZone: timeZone,
        bucket: .day,
        in: database
      )
    }
    let partition = statisticsRangePartition(for: query, timeZone: timeZone)
    var points: [HealthMetricPoint] = []
    if partition.hasCompleteDays,
      let completeStart = partition.completeStartLogicalDate,
      let completeEnd = partition.completeEndLogicalDate
    {
      let statement = try database.prepare(
        """
        SELECT logical_date, value, minimum, maximum, sample_count
        FROM health_archive_metric_daily_rollups
        WHERE time_zone_identifier = ? AND kind = ?
          AND logical_date >= ? AND logical_date < ?
        ORDER BY logical_date ASC
        """)
      try statement.bind(timeZone.identifier, at: 1)
      try statement.bind(definition.kind.rawValue, at: 2)
      try statement.bind(completeStart, at: 3)
      try statement.bind(completeEnd, at: 4)
      points.append(contentsOf: try decodeMetricPoints(statement, bucket: .day, timeZone: timeZone))
    }
    for interval in partition.partialIntervals {
      points.append(
        contentsOf: try rawMetricPoints(
          definition: definition,
          startsAt: interval.startsAt,
          endsAt: interval.endsAt,
          timeZone: timeZone,
          bucket: .day,
          in: database
        ))
    }
    return points.sorted { $0.startedAt < $1.startedAt }
  }

  private static func rawMetricPoints(
    definition: MetricDefinition,
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone,
    bucket: MetricBucket,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricPoint] {
    switch definition.projection {
    case .quantityAverage:
      guard let rawUnit = definition.rawUnit else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      return try quantityAveragePoints(
        kind: definition.kind,
        unit: rawUnit,
        startsAt: startsAt,
        endsAt: endsAt,
        timeZone: timeZone,
        bucket: bucket,
        in: database
      )
    case .reconciledQuantitySum:
      guard let rawUnit = definition.rawUnit else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      return try reconciledQuantityPoints(
        kind: definition.kind,
        unit: rawUnit,
        startsAt: startsAt,
        endsAt: endsAt,
        timeZone: timeZone,
        bucket: bucket,
        in: database
      )
    case .sleepDuration:
      guard bucket == .day else { return [] }
      return try reconciledSleepPoints(
        startsAt: startsAt,
        endsAt: endsAt,
        timeZone: timeZone,
        in: database
      )
    case .stoodHourCount:
      return try reconciledStoodHourPoints(
        startsAt: startsAt,
        endsAt: endsAt,
        timeZone: timeZone,
        bucket: bucket,
        in: database
      )
    case .categoryDuration, .workoutDuration:
      let payloadKind = definition.projection == .categoryDuration ? "category" : "workout"
      let valueExpression =
        definition.projection == .categoryDuration
        ? "MAX(0, ended_at - started_at)"
        : "MAX(0, CAST(json_extract(payload, '$.payload.duration') AS REAL))"
      return try reconciledDurationPoints(
        kind: definition.kind,
        payloadKind: payloadKind,
        valueExpression: valueExpression,
        startsAt: startsAt,
        endsAt: endsAt,
        timeZone: timeZone,
        bucket: bucket,
        in: database
      )
    }
  }

  private static func quantityAveragePoints(
    kind: HealthObservationKind,
    unit: String,
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone,
    bucket: MetricBucket,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricPoint] {
    let offsetExpression = localDayOffsetSQL(
      startsAt: startsAt,
      endsAt: endsAt,
      timeZone: timeZone
    )
    let bucketExpression: String
    switch bucket {
    case .day:
      bucketExpression =
        "strftime('%Y-%m-%d', ended_at + 978307200 + (\(offsetExpression)), 'unixepoch')"
    case .fiveMinutes, .quarterHour:
      guard let interval = bucket.interval else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      bucketExpression =
        "CAST(ended_at / \(Int(interval)) AS INTEGER) * \(Int(interval))"
    }
    let statement = try database.prepare(
      """
      SELECT \(bucketExpression) AS bucket,
             AVG(CAST(json_extract(payload, '$.payload.value') AS REAL)),
             MIN(CAST(json_extract(payload, '$.payload.value') AS REAL)),
             MAX(CAST(json_extract(payload, '$.payload.value') AS REAL)),
             COUNT(*)
      FROM health_archive_observations
      WHERE kind = ? AND ended_at >= ? AND ended_at <= ?
        AND json_extract(payload, '$.payload.kind') = 'quantity'
        AND json_extract(payload, '$.payload.unit') = ?
        AND json_type(payload, '$.payload.value') IN ('integer', 'real')
      GROUP BY bucket
      ORDER BY bucket ASC
      """)
    try statement.bind(kind.rawValue, at: 1)
    try statement.bind(startsAt.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(endsAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(unit, at: 4)
    return try decodeMetricPoints(statement, bucket: bucket, timeZone: timeZone)
  }

  private static func reconciledQuantityPoints(
    kind: HealthObservationKind,
    unit: String,
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone,
    bucket: MetricBucket,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricPoint] {
    let offsetExpression = localDayOffsetSQL(
      startsAt: startsAt,
      endsAt: endsAt,
      timeZone: timeZone
    )
    let outputBucket: String
    let sourceBucket: String
    switch bucket {
    case .day:
      outputBucket = "logical_date"
      sourceBucket =
        "strftime('%Y-%m-%d', ended_at + 978307200 + (\(offsetExpression)), 'unixepoch')"
    case .fiveMinutes, .quarterHour:
      guard let interval = bucket.interval else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      outputBucket = "interval_start"
      sourceBucket =
        "CAST(ended_at / \(Int(interval)) AS INTEGER) * \(Int(interval))"
    }
    let statement = try database.prepare(
      """
      WITH source_hours AS (
        SELECT \(sourceBucket) AS \(outputBucket),
               CAST(ended_at / 3600 AS INTEGER) AS absolute_hour,
               COALESCE(json_extract(payload, '$.source.bundleIdentifier'), source_installation_id) AS source,
               SUM(CAST(json_extract(payload, '$.payload.value') AS REAL)) AS source_value,
               COUNT(*) AS source_sample_count
        FROM health_archive_observations
        WHERE kind = ? AND ended_at >= ? AND ended_at <= ?
          AND json_extract(payload, '$.payload.kind') = 'quantity'
          AND json_extract(payload, '$.payload.unit') = ?
          AND json_type(payload, '$.payload.value') IN ('integer', 'real')
        GROUP BY \(outputBucket), absolute_hour, source
      ), reconciled_hours AS (
        SELECT \(outputBucket), absolute_hour,
               MAX(source_value) AS value,
               MAX(source_sample_count) AS sample_count
        FROM source_hours
        GROUP BY \(outputBucket), absolute_hour
      )
      SELECT \(outputBucket), SUM(value), MIN(value), MAX(value), SUM(sample_count)
      FROM reconciled_hours
      GROUP BY \(outputBucket)
      ORDER BY \(outputBucket) ASC
      """)
    try statement.bind(kind.rawValue, at: 1)
    try statement.bind(startsAt.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(endsAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(unit, at: 4)
    return try decodeMetricPoints(statement, bucket: bucket, timeZone: timeZone)
  }

  private static func reconciledStoodHourPoints(
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone,
    bucket: MetricBucket,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricPoint] {
    let offsetExpression = localDayOffsetSQL(
      startsAt: startsAt,
      endsAt: endsAt,
      timeZone: timeZone
    )
    let outputBucket: String
    let sourceBucket: String
    switch bucket {
    case .day:
      outputBucket = "logical_date"
      sourceBucket =
        "strftime('%Y-%m-%d', ended_at + 978307200 + (\(offsetExpression)), 'unixepoch')"
    case .fiveMinutes, .quarterHour:
      guard let interval = bucket.interval else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      outputBucket = "interval_start"
      sourceBucket = "CAST(ended_at / \(Int(interval)) AS INTEGER) * \(Int(interval))"
    }
    let statement = try database.prepare(
      """
      WITH source_hours AS (
        SELECT \(sourceBucket) AS \(outputBucket),
               CAST(ended_at / 3600 AS INTEGER) AS absolute_hour,
               COALESCE(json_extract(payload, '$.source.bundleIdentifier'), source_installation_id) AS source,
               MAX(CASE WHEN CAST(json_extract(payload, '$.payload.rawValue') AS INTEGER) = 0 THEN 1 ELSE 0 END) AS stood
        FROM health_archive_observations
        WHERE kind = ? AND ended_at >= ? AND ended_at <= ?
          AND json_extract(payload, '$.payload.kind') = 'category'
        GROUP BY \(outputBucket), absolute_hour, source
      ), reconciled_hours AS (
        SELECT \(outputBucket), absolute_hour, MAX(stood) AS stood
        FROM source_hours
        GROUP BY \(outputBucket), absolute_hour
      )
      SELECT \(outputBucket), SUM(stood), MIN(stood), MAX(stood), COUNT(*)
      FROM reconciled_hours
      GROUP BY \(outputBucket)
      ORDER BY \(outputBucket) ASC
      """)
    try statement.bind(HealthObservationKind.appleStandHour.rawValue, at: 1)
    try statement.bind(startsAt.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(endsAt.timeIntervalSinceReferenceDate, at: 3)
    return try decodeMetricPoints(statement, bucket: bucket, timeZone: timeZone)
  }

  private static func reconciledDurationPoints(
    kind: HealthObservationKind,
    payloadKind: String,
    valueExpression: String,
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone,
    bucket: MetricBucket,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricPoint] {
    let offsetExpression = localDayOffsetSQL(
      startsAt: startsAt,
      endsAt: endsAt,
      timeZone: timeZone
    )
    let outputBucket: String
    let sourceBucket: String
    switch bucket {
    case .day:
      outputBucket = "logical_date"
      sourceBucket =
        "strftime('%Y-%m-%d', ended_at + 978307200 + (\(offsetExpression)), 'unixepoch')"
    case .fiveMinutes, .quarterHour:
      guard let interval = bucket.interval else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      outputBucket = "interval_start"
      sourceBucket =
        "CAST(ended_at / \(Int(interval)) AS INTEGER) * \(Int(interval))"
    }
    let statement = try database.prepare(
      """
      WITH source_hours AS (
        SELECT \(sourceBucket) AS \(outputBucket),
               CAST(ended_at / 3600 AS INTEGER) AS absolute_hour,
               COALESCE(json_extract(payload, '$.source.bundleIdentifier'), source_installation_id) AS source,
               SUM(\(valueExpression)) AS source_value,
               COUNT(*) AS source_sample_count
        FROM health_archive_observations
        WHERE kind = ? AND ended_at >= ? AND ended_at <= ?
          AND json_extract(payload, '$.payload.kind') = ?
        GROUP BY \(outputBucket), absolute_hour, source
      ), reconciled_hours AS (
        SELECT \(outputBucket), absolute_hour,
               MAX(source_value) AS value,
               MAX(source_sample_count) AS sample_count
        FROM source_hours
        GROUP BY \(outputBucket), absolute_hour
      )
      SELECT \(outputBucket), SUM(value), MIN(value), MAX(value), SUM(sample_count)
      FROM reconciled_hours
      GROUP BY \(outputBucket)
      ORDER BY \(outputBucket) ASC
      """)
    try statement.bind(kind.rawValue, at: 1)
    try statement.bind(startsAt.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(endsAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(payloadKind, at: 4)
    return try decodeMetricPoints(statement, bucket: bucket, timeZone: timeZone)
  }

  private static func reconciledSleepPoints(
    startsAt: Date,
    endsAt: Date,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws -> [HealthMetricPoint] {
    let contextStartsAt = startsAt.addingTimeInterval(-36 * 60 * 60)
    let offsetExpression = localDayOffsetSQL(
      startsAt: startsAt,
      endsAt: endsAt,
      timeZone: timeZone
    )
    let dayExpression =
      "strftime('%Y-%m-%d', ended_at + 978307200 + (\(offsetExpression)), 'unixepoch')"
    let statement = try database.prepare(
      """
      WITH filtered_intervals AS (
        SELECT COALESCE(json_extract(payload, '$.source.bundleIdentifier'), source_installation_id) AS source,
               healthkit_uuid, started_at, ended_at
        FROM health_archive_observations
        WHERE kind = 'sleepAnalysis' AND ended_at >= ? AND ended_at <= ?
          AND json_extract(payload, '$.payload.kind') = 'category'
          AND CAST(json_extract(payload, '$.payload.rawValue') AS INTEGER) IN (1, 3, 4, 5)
      ), ordered_intervals AS (
        SELECT source, healthkit_uuid, started_at, ended_at,
               LAG(ended_at) OVER (
                 PARTITION BY source ORDER BY started_at, ended_at, healthkit_uuid
               ) AS previous_ended_at
        FROM filtered_intervals
      ), marked_sessions AS (
        SELECT source, healthkit_uuid, started_at, ended_at,
               CASE
                 WHEN previous_ended_at IS NULL OR started_at - previous_ended_at > 10800 THEN 1
                 ELSE 0
               END AS begins_new_session
        FROM ordered_intervals
      ), sessionized_intervals AS (
        SELECT source, started_at, ended_at,
               SUM(begins_new_session) OVER (
                 PARTITION BY source
                 ORDER BY started_at, ended_at, healthkit_uuid
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
               ) AS session_id
        FROM marked_sessions
      ), source_sessions AS (
        SELECT source, session_id,
               SUM(MAX(0, ended_at - started_at)) AS session_value,
               COUNT(*) AS session_sample_count,
               MAX(ended_at) AS ended_at
        FROM sessionized_intervals
        GROUP BY source, session_id
      ), source_days AS (
        SELECT \(dayExpression) AS logical_date, source,
               SUM(session_value) AS source_value,
               SUM(session_sample_count) AS source_sample_count
        FROM source_sessions
        GROUP BY logical_date, source
      )
      SELECT logical_date, MAX(source_value), NULL, NULL, MAX(source_sample_count)
      FROM source_days
      WHERE logical_date >= ? AND logical_date <= ?
      GROUP BY logical_date
      ORDER BY logical_date ASC
      """)
    try statement.bind(contextStartsAt.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(endsAt.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(logicalDate(for: startsAt, timeZone: timeZone), at: 3)
    try statement.bind(logicalDate(for: endsAt, timeZone: timeZone), at: 4)
    return try decodeMetricPoints(statement, bucket: .day, timeZone: timeZone)
  }

  private static func latestQuantityPoint(
    kind: HealthObservationKind,
    unit: String,
    startsAt: Date,
    endsAt: Date,
    in database: SQLiteDatabase
  ) throws -> HealthMetricPoint? {
    let statement = try database.prepare(
      """
      SELECT started_at, ended_at,
             CAST(json_extract(payload, '$.payload.value') AS REAL)
      FROM health_archive_observations
      WHERE kind = ? AND ended_at >= ? AND ended_at <= ?
        AND json_extract(payload, '$.payload.kind') = 'quantity'
        AND json_extract(payload, '$.payload.unit') = ?
        AND json_type(payload, '$.payload.value') IN ('integer', 'real')
      ORDER BY ended_at DESC, healthkit_uuid ASC
      LIMIT 1
      """)
    try statement.bind(kind.rawValue, at: 1)
    try statement.bind(startsAt.timeIntervalSinceReferenceDate, at: 2)
    try statement.bind(endsAt.timeIntervalSinceReferenceDate, at: 3)
    try statement.bind(unit, at: 4)
    guard try statement.stepRow() else { return nil }
    let value = try statement.requiredDouble(at: 2, column: "value")
    guard value.isFinite else { throw HealthArchiveStoreError.invalidStoredPayload }
    let point = HealthMetricPoint(
      startedAt: Date(
        timeIntervalSinceReferenceDate: try statement.requiredDouble(at: 0, column: "started_at")
      ),
      endedAt: Date(
        timeIntervalSinceReferenceDate: try statement.requiredDouble(at: 1, column: "ended_at")
      ),
      value: value,
      minimum: value,
      maximum: value,
      contributingSampleCount: 1
    )
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return point
  }

  private static func decodeMetricPoints(
    _ statement: SQLiteStatement,
    bucket: MetricBucket,
    timeZone: TimeZone
  ) throws -> [HealthMetricPoint] {
    var points: [HealthMetricPoint] = []
    while try statement.stepRow() {
      let bounds: Range<Date>
      switch bucket {
      case .day:
        let logicalDate = try statement.requiredText(at: 0, column: "logical_date")
        guard let dayBounds = localDayBounds(logicalDate, timeZone: timeZone) else {
          throw HealthArchiveStoreError.invalidStoredPayload
        }
        bounds = dayBounds
      case .fiveMinutes, .quarterHour:
        guard let interval = bucket.interval else {
          throw HealthArchiveStoreError.invalidStoredPayload
        }
        let start = Date(
          timeIntervalSinceReferenceDate: try statement.requiredDouble(
            at: 0,
            column: "interval_start"
          )
        )
        bounds = start..<start.addingTimeInterval(interval)
      }
      let value = try statement.requiredDouble(at: 1, column: "value")
      let minimum =
        statement.isNull(at: 2) ? nil : try statement.requiredDouble(at: 2, column: "minimum")
      let maximum =
        statement.isNull(at: 3) ? nil : try statement.requiredDouble(at: 3, column: "maximum")
      guard value.isFinite,
        minimum?.isFinite ?? true,
        maximum?.isFinite ?? true,
        let sampleCount = Int(exactly: try statement.requiredInt64(at: 4, column: "sample_count")),
        sampleCount >= 0
      else { throw HealthArchiveStoreError.invalidStoredPayload }
      points.append(
        HealthMetricPoint(
          startedAt: bounds.lowerBound,
          endedAt: bounds.upperBound,
          value: value,
          minimum: minimum,
          maximum: maximum,
          contributingSampleCount: sampleCount
        ))
    }
    return points
  }

  private static func mergeDailyCounts(
    _ statement: SQLiteStatement,
    into aggregate: inout [String: Int]
  ) throws {
    while try statement.stepRow() {
      let logicalDate = try statement.requiredText(at: 0, column: "logical_date")
      guard
        let count = Int(exactly: try statement.requiredInt64(at: 1, column: "observation_count")),
        count >= 0
      else { throw HealthArchiveStoreError.invalidStoredPayload }
      aggregate[logicalDate, default: 0] += count
    }
  }

  private static func partialDailyCountsStatement(
    query: HealthArchiveStatisticsQuery,
    interval: ObservationInterval,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws -> SQLiteStatement {
    let kinds = query.kinds?.map(\.rawValue).sorted() ?? []
    let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
    let kindClause = kinds.isEmpty ? "" : " AND kind IN (\(placeholders))"
    let offsetExpression = localDayOffsetSQL(
      startsAt: interval.startsAt,
      endsAt: interval.endsAt,
      timeZone: timeZone
    )
    let endComparison = interval.includesEnd ? "<=" : "<"
    let statement = try database.prepare(
      """
      SELECT strftime('%Y-%m-%d', ended_at + 978307200 + (\(offsetExpression)), 'unixepoch') AS logical_date,
             COUNT(*)
      FROM health_archive_observations
      WHERE ended_at >= ? AND ended_at \(endComparison) ?\(kindClause)
      GROUP BY logical_date
      ORDER BY logical_date ASC
      """)
    try statement.bind(interval.startsAt.timeIntervalSinceReferenceDate, at: 1)
    try statement.bind(interval.endsAt.timeIntervalSinceReferenceDate, at: 2)
    var index: Int32 = 3
    for kind in kinds {
      try statement.bind(kind, at: index)
      index += 1
    }
    return statement
  }

  static func statisticsState(in database: SQLiteDatabase) throws -> StatisticsState {
    let statement = try database.prepare(
      """
      SELECT archive_revision, observation_count, received_batch_count,
             earliest_ended_at, latest_ended_at, latest_batch_received_at
      FROM health_archive_statistics_state
      WHERE singleton = 1
      """)
    guard try statement.stepRow(),
      let revision = UInt64(
        exactly: try statement.requiredInt64(at: 0, column: "archive_revision")),
      let observationCount = Int(
        exactly: try statement.requiredInt64(at: 1, column: "observation_count")),
      let batchCount = Int(
        exactly: try statement.requiredInt64(at: 2, column: "received_batch_count")),
      observationCount >= 0,
      batchCount >= 0
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    let state = StatisticsState(
      revision: revision,
      observationCount: observationCount,
      receivedBatchCount: batchCount,
      earliestEndedAt: try optionalDate(statement, at: 3, column: "earliest_ended_at"),
      latestEndedAt: try optionalDate(statement, at: 4, column: "latest_ended_at"),
      latestBatchReceivedAt: try optionalDate(statement, at: 5, column: "latest_batch_received_at")
    )
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return state
  }

  static func fallbackStatisticsState(
    revision: UInt64,
    in database: SQLiteDatabase
  ) throws -> StatisticsState {
    let observations = try database.prepare(
      "SELECT COUNT(*), MIN(ended_at), MAX(ended_at) FROM health_archive_observations")
    guard try observations.stepRow(),
      let count = Int(exactly: try observations.requiredInt64(at: 0, column: "count"))
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    let earliest = try optionalDate(observations, at: 1, column: "earliest_ended_at")
    let latest = try optionalDate(observations, at: 2, column: "latest_ended_at")
    let batches = try database.prepare(
      "SELECT COUNT(*), MAX(received_at) FROM health_archive_batches")
    guard try batches.stepRow(),
      let batchCount = Int(exactly: try batches.requiredInt64(at: 0, column: "batch_count"))
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    return StatisticsState(
      revision: revision,
      observationCount: count,
      receivedBatchCount: batchCount,
      earliestEndedAt: earliest,
      latestEndedAt: latest,
      latestBatchReceivedAt: try optionalDate(
        batches, at: 1, column: "latest_batch_received_at")
    )
  }

  static func fallbackSummary(
    state: StatisticsState,
    in database: SQLiteDatabase
  ) throws -> HealthArchiveSummary {
    let statement = try database.prepare(
      """
      SELECT COUNT(DISTINCT kind), COUNT(DISTINCT source_installation_id)
      FROM health_archive_observations
      """)
    guard try statement.stepRow(),
      let kindCount = Int(exactly: try statement.requiredInt64(at: 0, column: "kind_count")),
      let sourceCount = Int(exactly: try statement.requiredInt64(at: 1, column: "source_count"))
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    return HealthArchiveSummary(
      observationCount: state.observationCount,
      coveredKindCount: kindCount,
      sourceInstallationCount: sourceCount,
      receivedBatchCount: state.receivedBatchCount,
      earliestEndedAt: state.earliestEndedAt,
      latestEndedAt: state.latestEndedAt,
      latestBatchReceivedAt: state.latestBatchReceivedAt
    )
  }

  private static func optionalDate(
    _ statement: SQLiteStatement,
    at index: Int32,
    column: String
  ) throws -> Date? {
    guard !statement.isNull(at: index) else { return nil }
    let interval = try statement.requiredDouble(at: index, column: column)
    guard interval.isFinite else { throw HealthArchiveStoreError.invalidStoredPayload }
    return Date(timeIntervalSinceReferenceDate: interval)
  }

  static func advancedRevision(_ revision: UInt64) throws -> UInt64 {
    let (advanced, overflow) = revision.addingReportingOverflow(1)
    guard !overflow, Int64(exactly: advanced) != nil else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    return advanced
  }

  static func updateStatisticsState(
    revision: UInt64,
    observationCount: Int,
    receivedBatchCount: Int,
    latestBatchReceivedAt: Date?,
    previousState: StatisticsState,
    insertedEndedAts: [Date],
    removedEndedAts: Set<Date>,
    in database: SQLiteDatabase
  ) throws {
    guard observationCount >= 0,
      receivedBatchCount >= 0,
      let storedRevision = Int64(exactly: revision)
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    let insertedEarliest = insertedEndedAts.min()
    let insertedLatest = insertedEndedAts.max()
    let earliest: Date?
    let latest: Date?
    if observationCount == 0 {
      earliest = nil
      latest = nil
    } else {
      let invalidatesEarliest =
        previousState.earliestEndedAt.map { previous in
          removedEndedAts.contains(previous) && (insertedEarliest.map { $0 > previous } ?? true)
        } ?? false
      let invalidatesLatest =
        previousState.latestEndedAt.map { previous in
          removedEndedAts.contains(previous) && (insertedLatest.map { $0 < previous } ?? true)
        } ?? false
      if invalidatesEarliest {
        earliest = try extremeEndedAt(order: "ASC", in: database)
      } else {
        earliest = [previousState.earliestEndedAt, insertedEarliest].compactMap { $0 }.min()
      }
      if invalidatesLatest {
        latest = try extremeEndedAt(order: "DESC", in: database)
      } else {
        latest = [previousState.latestEndedAt, insertedLatest].compactMap { $0 }.max()
      }
    }

    let statement = try database.prepare(
      """
      UPDATE health_archive_statistics_state
      SET archive_revision = ?, observation_count = ?, received_batch_count = ?,
          earliest_ended_at = ?, latest_ended_at = ?, latest_batch_received_at = ?
      WHERE singleton = 1
      """)
    try statement.bind(storedRevision, at: 1)
    try statement.bind(Int64(observationCount), at: 2)
    try statement.bind(Int64(receivedBatchCount), at: 3)
    try bind(earliest, to: statement, at: 4)
    try bind(latest, to: statement, at: 5)
    try bind(latestBatchReceivedAt, to: statement, at: 6)
    try statement.expectDone()
  }

  private static func extremeEndedAt(
    order: String,
    in database: SQLiteDatabase
  ) throws -> Date? {
    guard order == "ASC" || order == "DESC" else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    let statement = try database.prepare(
      "SELECT ended_at FROM health_archive_observations ORDER BY ended_at \(order) LIMIT 1"
    )
    guard try statement.stepRow() else { return nil }
    let date = Date(
      timeIntervalSinceReferenceDate: try statement.requiredDouble(at: 0, column: "ended_at"))
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return date
  }

  private static func bind(_ date: Date?, to statement: SQLiteStatement, at index: Int32) throws {
    if let date {
      try statement.bind(date.timeIntervalSinceReferenceDate, at: index)
    } else {
      try statement.bindNull(at: index)
    }
  }

  static func storedObservationIndex(
    for key: HealthObservationKey,
    in database: SQLiteDatabase
  ) throws -> StoredObservationIndex? {
    let statement = try database.prepare(
      """
      SELECT source_installation_id, kind, ended_at
      FROM health_archive_observations
      WHERE source_installation_id = ? AND healthkit_uuid = ?
      """)
    try statement.bind(uuid(key.sourceInstallationID), at: 1)
    try statement.bind(uuid(key.healthKitUUID), at: 2)
    guard try statement.stepRow() else { return nil }
    guard
      let source = UUID(
        uuidString: try statement.requiredText(at: 0, column: "source_installation_id")),
      let kind = HealthObservationKind(rawValue: try statement.requiredText(at: 1, column: "kind"))
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    let value = StoredObservationIndex(
      sourceInstallationID: source,
      kind: kind,
      endedAt: Date(
        timeIntervalSinceReferenceDate: try statement.requiredDouble(at: 2, column: "ended_at")
      )
    )
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return value
  }

  static func applyKindTotalDeltas(
    _ deltas: [HealthObservationKind: Int],
    latestCandidates: [HealthObservationKind: Date],
    removedObservationTimes: [HealthObservationKind: Set<Date>],
    in database: SQLiteDatabase
  ) throws {
    let affectedKinds = Set(deltas.keys)
      .union(latestCandidates.keys)
      .union(removedObservationTimes.keys)
    for kind in affectedKinds {
      let current = try database.prepare(
        """
        SELECT observation_count, latest_ended_at
        FROM health_archive_kind_totals WHERE kind = ?
        """)
      try current.bind(kind.rawValue, at: 1)
      let hasCurrent = try current.stepRow()
      let currentCount =
        hasCurrent
        ? Int(exactly: try current.requiredInt64(at: 0, column: "observation_count")) : nil
      let currentLatest =
        hasCurrent
        ? Date(
          timeIntervalSinceReferenceDate: try current.requiredDouble(
            at: 1, column: "latest_ended_at")) : nil
      if hasCurrent, try current.stepRow() {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      let oldCount = currentCount ?? 0
      let newCount = oldCount + (deltas[kind] ?? 0)
      guard newCount >= 0 else { throw HealthArchiveStoreError.invalidStoredPayload }
      if newCount == 0 {
        let delete = try database.prepare("DELETE FROM health_archive_kind_totals WHERE kind = ?")
        try delete.bind(kind.rawValue, at: 1)
        try delete.expectDone()
        continue
      }
      let candidate = latestCandidates[kind]
      let invalidatesLatest =
        currentLatest.map { latest in
          removedObservationTimes[kind]?.contains(latest) == true
            && (candidate.map { $0 < latest } ?? true)
        } ?? false
      let latest =
        invalidatesLatest
        ? try latestEndedAt(for: kind, in: database)
        : [currentLatest, candidate].compactMap { $0 }.max()
      guard let latest else { throw HealthArchiveStoreError.invalidStoredPayload }
      let upsert = try database.prepare(
        """
        INSERT INTO health_archive_kind_totals(kind, observation_count, latest_ended_at)
        VALUES (?, ?, ?)
        ON CONFLICT(kind) DO UPDATE SET
          observation_count = excluded.observation_count,
          latest_ended_at = excluded.latest_ended_at
        """)
      try upsert.bind(kind.rawValue, at: 1)
      try upsert.bind(Int64(newCount), at: 2)
      try upsert.bind(latest.timeIntervalSinceReferenceDate, at: 3)
      try upsert.expectDone()
    }
  }

  private static func latestEndedAt(
    for kind: HealthObservationKind,
    in database: SQLiteDatabase
  ) throws -> Date? {
    let statement = try database.prepare(
      """
      SELECT ended_at FROM health_archive_observations
      WHERE kind = ? ORDER BY ended_at DESC LIMIT 1
      """)
    try statement.bind(kind.rawValue, at: 1)
    guard try statement.stepRow() else { return nil }
    let result = Date(
      timeIntervalSinceReferenceDate: try statement.requiredDouble(at: 0, column: "ended_at"))
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return result
  }

  static func applySourceTotalDeltas(
    _ deltas: [UUID: Int],
    in database: SQLiteDatabase
  ) throws {
    for (source, delta) in deltas where delta != 0 {
      let sourceID = uuid(source)
      let current = try database.prepare(
        """
        SELECT observation_count FROM health_archive_source_totals
        WHERE source_installation_id = ?
        """)
      try current.bind(sourceID, at: 1)
      let hasCurrent = try current.stepRow()
      let oldCount =
        hasCurrent
        ? Int(exactly: try current.requiredInt64(at: 0, column: "observation_count")) : 0
      if hasCurrent, try current.stepRow() {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      guard let oldCount else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      let newCount = oldCount + delta
      guard newCount >= 0 else { throw HealthArchiveStoreError.invalidStoredPayload }
      if newCount == 0 {
        let delete = try database.prepare(
          "DELETE FROM health_archive_source_totals WHERE source_installation_id = ?")
        try delete.bind(sourceID, at: 1)
        try delete.expectDone()
      } else {
        let upsert = try database.prepare(
          """
          INSERT INTO health_archive_source_totals(source_installation_id, observation_count)
          VALUES (?, ?)
          ON CONFLICT(source_installation_id) DO UPDATE SET
            observation_count = excluded.observation_count
          """)
        try upsert.bind(sourceID, at: 1)
        try upsert.bind(Int64(newCount), at: 2)
        try upsert.expectDone()
      }
    }
  }

  static func rollupRevision(
    for timeZoneIdentifier: String,
    in database: SQLiteDatabase
  ) throws -> UInt64? {
    let statement = try database.prepare(
      """
      SELECT archive_revision FROM health_archive_rollup_states
      WHERE time_zone_identifier = ?
      """)
    try statement.bind(timeZoneIdentifier, at: 1)
    guard try statement.stepRow() else { return nil }
    guard
      let revision = UInt64(
        exactly: try statement.requiredInt64(at: 0, column: "archive_revision")
      )
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return revision
  }

  static func setRollupRevision(
    _ revision: UInt64,
    for timeZoneIdentifier: String,
    in database: SQLiteDatabase
  ) throws {
    guard let storedRevision = Int64(exactly: revision) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    let statement = try database.prepare(
      """
      INSERT INTO health_archive_rollup_states(time_zone_identifier, archive_revision)
      VALUES (?, ?)
      ON CONFLICT(time_zone_identifier) DO UPDATE SET archive_revision = excluded.archive_revision
      """)
    try statement.bind(timeZoneIdentifier, at: 1)
    try statement.bind(storedRevision, at: 2)
    try statement.expectDone()
  }

  static func metricRollupRevision(
    for timeZoneIdentifier: String,
    in database: SQLiteDatabase
  ) throws -> UInt64? {
    let statement = try database.prepare(
      """
      SELECT archive_revision, target_revision, next_definition_index
      FROM health_archive_metric_rollup_states
      WHERE time_zone_identifier = ?
      """)
    try statement.bind(timeZoneIdentifier, at: 1)
    guard try statement.stepRow() else { return nil }
    guard
      let revision = UInt64(
        exactly: try statement.requiredInt64(at: 0, column: "archive_revision")),
      let target = UInt64(exactly: try statement.requiredInt64(at: 1, column: "target_revision")),
      let nextIndex = Int(
        exactly: try statement.requiredInt64(at: 2, column: "next_definition_index"))
    else { throw HealthArchiveStoreError.invalidStoredPayload }
    guard !(try statement.stepRow()) else { throw HealthArchiveStoreError.invalidStoredPayload }
    return nextIndex == metricDefinitions.count && revision == target ? revision : nil
  }

  static func setMetricRollupRevision(
    _ revision: UInt64,
    for timeZoneIdentifier: String,
    in database: SQLiteDatabase
  ) throws {
    guard let storedRevision = Int64(exactly: revision) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    let statement = try database.prepare(
      """
      INSERT INTO health_archive_metric_rollup_states(
        time_zone_identifier, archive_revision, target_revision, next_definition_index
      ) VALUES (?, ?, ?, ?)
      ON CONFLICT(time_zone_identifier) DO UPDATE SET
        archive_revision = excluded.archive_revision,
        target_revision = excluded.target_revision,
        next_definition_index = excluded.next_definition_index
      """)
    try statement.bind(timeZoneIdentifier, at: 1)
    try statement.bind(storedRevision, at: 2)
    try statement.bind(storedRevision, at: 3)
    try statement.bind(Int64(metricDefinitions.count), at: 4)
    try statement.expectDone()
  }

  static func prepareMetricRollupBackfill(
    revision: UInt64,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws {
    guard let storedRevision = Int64(exactly: revision) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    try database.transaction {
      let existing = try database.prepare(
        """
        SELECT target_revision FROM health_archive_metric_rollup_states
        WHERE time_zone_identifier = ?
        """)
      try existing.bind(timeZone.identifier, at: 1)
      if try existing.stepRow(),
        try existing.requiredInt64(at: 0, column: "target_revision") == storedRevision
      {
        return
      }
      let delete = try database.prepare(
        "DELETE FROM health_archive_metric_daily_rollups WHERE time_zone_identifier = ?"
      )
      try delete.bind(timeZone.identifier, at: 1)
      try delete.expectDone()
      let progress = try database.prepare(
        """
        INSERT INTO health_archive_metric_rollup_states(
          time_zone_identifier, archive_revision, target_revision, next_definition_index
        ) VALUES (?, 0, ?, 0)
        ON CONFLICT(time_zone_identifier) DO UPDATE SET
          archive_revision = 0,
          target_revision = excluded.target_revision,
          next_definition_index = 0
        """)
      try progress.bind(timeZone.identifier, at: 1)
      try progress.bind(storedRevision, at: 2)
      try progress.expectDone()
    }
  }

  static func rebuildNextMetricRollupDefinition(
    revision: UInt64,
    timeZone: TimeZone,
    state: StatisticsState,
    in database: SQLiteDatabase
  ) throws -> Bool {
    guard let storedRevision = Int64(exactly: revision) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    return try database.transaction {
      let currentState = try statisticsState(in: database)
      guard currentState.revision == revision else { return false }
      let progress = try database.prepare(
        """
        SELECT target_revision, next_definition_index
        FROM health_archive_metric_rollup_states
        WHERE time_zone_identifier = ?
        """)
      try progress.bind(timeZone.identifier, at: 1)
      guard try progress.stepRow(),
        try progress.requiredInt64(at: 0, column: "target_revision") == storedRevision,
        let nextIndex = Int(
          exactly: try progress.requiredInt64(at: 1, column: "next_definition_index")),
        metricDefinitions.indices.contains(nextIndex)
      else { return false }

      let definition = metricDefinitions[nextIndex]
      let delete = try database.prepare(
        """
        DELETE FROM health_archive_metric_daily_rollups
        WHERE time_zone_identifier = ? AND kind = ?
        """)
      try delete.bind(timeZone.identifier, at: 1)
      try delete.bind(definition.kind.rawValue, at: 2)
      try delete.expectDone()
      if definition.projection != .sleepDuration,
        let earliest = state.earliestEndedAt,
        let latest = state.latestEndedAt
      {
        let points = try rawMetricPoints(
          definition: definition,
          startsAt: earliest,
          endsAt: latest,
          timeZone: timeZone,
          bucket: .day,
          in: database
        )
        for point in points {
          try insertMetricRollupPoint(
            point,
            kind: definition.kind,
            timeZone: timeZone,
            in: database
          )
        }
      }
      let advancedIndex = nextIndex + 1
      if advancedIndex == metricDefinitions.count {
        try setMetricRollupRevision(revision, for: timeZone.identifier, in: database)
      } else {
        let update = try database.prepare(
          """
          UPDATE health_archive_metric_rollup_states
          SET next_definition_index = ?
          WHERE time_zone_identifier = ? AND target_revision = ?
          """)
        try update.bind(Int64(advancedIndex), at: 1)
        try update.bind(timeZone.identifier, at: 2)
        try update.bind(storedRevision, at: 3)
        try update.expectDone()
      }
      return true
    }
  }

  static func rebuildMetricRollupCells(
    _ cells: Set<DailyRollupCell>,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws {
    let definitionsByKind = Dictionary(
      uniqueKeysWithValues: metricDefinitions.map { ($0.kind, $0) }
    )
    for cell in cells {
      let delete = try database.prepare(
        """
        DELETE FROM health_archive_metric_daily_rollups
        WHERE time_zone_identifier = ? AND logical_date = ? AND kind = ?
        """)
      try delete.bind(timeZone.identifier, at: 1)
      try delete.bind(cell.logicalDate, at: 2)
      try delete.bind(cell.kind.rawValue, at: 3)
      try delete.expectDone()
      guard let definition = definitionsByKind[cell.kind],
        let bounds = localDayBounds(cell.logicalDate, timeZone: timeZone)
      else { continue }
      let startsAt =
        definition.projection == .sleepDuration
        ? bounds.lowerBound.addingTimeInterval(-36 * 60 * 60)
        : bounds.lowerBound
      let exclusiveUpperInterval = bounds.upperBound.timeIntervalSinceReferenceDate.nextDown
      let endsAt = Date(timeIntervalSinceReferenceDate: exclusiveUpperInterval)
      let points = try rawMetricPoints(
        definition: definition,
        startsAt: startsAt,
        endsAt: endsAt,
        timeZone: timeZone,
        bucket: .day,
        in: database
      )
      if let point = points.first(where: {
        logicalDate(for: $0.startedAt, timeZone: timeZone) == cell.logicalDate
      }) {
        try insertMetricRollupPoint(
          point,
          kind: definition.kind,
          timeZone: timeZone,
          in: database
        )
      }
    }
  }

  private static func insertMetricRollupPoint(
    _ point: HealthMetricPoint,
    kind: HealthObservationKind,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws {
    let statement = try database.prepare(
      """
      INSERT INTO health_archive_metric_daily_rollups(
        time_zone_identifier, logical_date, kind, value, minimum, maximum, sample_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      """)
    try statement.bind(timeZone.identifier, at: 1)
    try statement.bind(logicalDate(for: point.startedAt, timeZone: timeZone), at: 2)
    try statement.bind(kind.rawValue, at: 3)
    try statement.bind(point.value, at: 4)
    if let minimum = point.minimum {
      try statement.bind(minimum, at: 5)
    } else {
      try statement.bindNull(at: 5)
    }
    if let maximum = point.maximum {
      try statement.bind(maximum, at: 6)
    } else {
      try statement.bindNull(at: 6)
    }
    try statement.bind(Int64(point.contributingSampleCount), at: 7)
    try statement.expectDone()
  }

  static func prepareDailyRollupBackfill(
    revision: UInt64,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws {
    guard let storedRevision = Int64(exactly: revision) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    try database.transaction {
      let progress = try database.prepare(
        """
        SELECT target_revision FROM health_archive_daily_rollup_build_states
        WHERE time_zone_identifier = ?
        """)
      try progress.bind(timeZone.identifier, at: 1)
      if try progress.stepRow(),
        try progress.requiredInt64(at: 0, column: "target_revision") == storedRevision
      {
        return
      }
      let delete = try database.prepare(
        "DELETE FROM health_archive_daily_rollups WHERE time_zone_identifier = ?")
      try delete.bind(timeZone.identifier, at: 1)
      try delete.expectDone()
      let reset = try database.prepare(
        """
        INSERT INTO health_archive_daily_rollup_build_states(
          time_zone_identifier, target_revision, next_kind_index
        ) VALUES (?, ?, 0)
        ON CONFLICT(time_zone_identifier) DO UPDATE SET
          target_revision = excluded.target_revision,
          next_kind_index = 0
        """)
      try reset.bind(timeZone.identifier, at: 1)
      try reset.bind(storedRevision, at: 2)
      try reset.expectDone()
    }
  }

  static func rebuildNextDailyRollupKind(
    revision: UInt64,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws -> Bool {
    let kinds = HealthObservationKind.allCases.sorted { $0.rawValue < $1.rawValue }
    guard let storedRevision = Int64(exactly: revision) else {
      throw HealthArchiveStoreError.invalidStoredPayload
    }
    return try database.transaction {
      let state = try statisticsState(in: database)
      guard state.revision == revision else { return false }
      let progress = try database.prepare(
        """
        SELECT target_revision, next_kind_index
        FROM health_archive_daily_rollup_build_states
        WHERE time_zone_identifier = ?
        """)
      try progress.bind(timeZone.identifier, at: 1)
      guard try progress.stepRow(),
        try progress.requiredInt64(at: 0, column: "target_revision") == storedRevision,
        let nextIndex = Int(
          exactly: try progress.requiredInt64(at: 1, column: "next_kind_index")),
        kinds.indices.contains(nextIndex)
      else { return false }
      let kind = kinds[nextIndex]
      let extrema = try database.prepare(
        "SELECT MIN(ended_at), MAX(ended_at) FROM health_archive_observations WHERE kind = ?")
      try extrema.bind(kind.rawValue, at: 1)
      guard try extrema.stepRow() else { throw HealthArchiveStoreError.invalidStoredPayload }
      if let earliest = try optionalDate(extrema, at: 0, column: "earliest"),
        let latest = try optionalDate(extrema, at: 1, column: "latest")
      {
        let offsetExpression = localDayOffsetSQL(
          startsAt: earliest, endsAt: latest, timeZone: timeZone)
        let insert = try database.prepare(
          """
          INSERT INTO health_archive_daily_rollups(
            time_zone_identifier, logical_date, kind, observation_count, latest_ended_at
          )
          SELECT ?,
                 strftime('%Y-%m-%d', ended_at + 978307200 + (\(offsetExpression)), 'unixepoch'),
                 kind, COUNT(*), MAX(ended_at)
          FROM health_archive_observations
          WHERE kind = ?
          GROUP BY 2, kind
          """)
        try insert.bind(timeZone.identifier, at: 1)
        try insert.bind(kind.rawValue, at: 2)
        try insert.expectDone()
      }
      let advanced = nextIndex + 1
      if advanced == kinds.count {
        try setRollupRevision(revision, for: timeZone.identifier, in: database)
        let clear = try database.prepare(
          "DELETE FROM health_archive_daily_rollup_build_states WHERE time_zone_identifier = ?")
        try clear.bind(timeZone.identifier, at: 1)
        try clear.expectDone()
      } else {
        let update = try database.prepare(
          """
          UPDATE health_archive_daily_rollup_build_states SET next_kind_index = ?
          WHERE time_zone_identifier = ? AND target_revision = ?
          """)
        try update.bind(Int64(advanced), at: 1)
        try update.bind(timeZone.identifier, at: 2)
        try update.bind(storedRevision, at: 3)
        try update.expectDone()
      }
      return true
    }
  }

  static func rebuildRollupCells(
    _ cells: Set<DailyRollupCell>,
    timeZone: TimeZone,
    in database: SQLiteDatabase
  ) throws {
    for cell in cells {
      let delete = try database.prepare(
        """
        DELETE FROM health_archive_daily_rollups
        WHERE time_zone_identifier = ? AND logical_date = ? AND kind = ?
        """)
      try delete.bind(timeZone.identifier, at: 1)
      try delete.bind(cell.logicalDate, at: 2)
      try delete.bind(cell.kind.rawValue, at: 3)
      try delete.expectDone()
      guard let bounds = localDayBounds(cell.logicalDate, timeZone: timeZone) else {
        throw HealthArchiveStoreError.invalidStoredPayload
      }
      let insert = try database.prepare(
        """
        INSERT INTO health_archive_daily_rollups(
          time_zone_identifier, logical_date, kind, observation_count, latest_ended_at
        )
        SELECT ?, ?, kind, COUNT(*), MAX(ended_at)
        FROM health_archive_observations
        WHERE kind = ? AND ended_at >= ? AND ended_at < ?
        GROUP BY kind
        """)
      try insert.bind(timeZone.identifier, at: 1)
      try insert.bind(cell.logicalDate, at: 2)
      try insert.bind(cell.kind.rawValue, at: 3)
      try insert.bind(bounds.lowerBound.timeIntervalSinceReferenceDate, at: 4)
      try insert.bind(bounds.upperBound.timeIntervalSinceReferenceDate, at: 5)
      try insert.expectDone()
    }
  }

  static func rollupCell(
    for observation: HealthObservation,
    timeZone: TimeZone
  ) -> DailyRollupCell {
    DailyRollupCell(
      logicalDate: logicalDate(for: observation.endedAt, timeZone: timeZone),
      kind: observation.kind
    )
  }

  static func rollupCell(
    for observation: StoredObservationIndex,
    timeZone: TimeZone
  ) -> DailyRollupCell {
    DailyRollupCell(
      logicalDate: logicalDate(for: observation.endedAt, timeZone: timeZone),
      kind: observation.kind
    )
  }

  static func metricRollupCells(
    for observation: HealthObservation,
    timeZone: TimeZone
  ) -> Set<DailyRollupCell> {
    metricRollupCells(
      kind: observation.kind,
      endedAt: observation.endedAt,
      timeZone: timeZone
    )
  }

  static func metricRollupCells(
    for observation: StoredObservationIndex,
    timeZone: TimeZone
  ) -> Set<DailyRollupCell> {
    metricRollupCells(
      kind: observation.kind,
      endedAt: observation.endedAt,
      timeZone: timeZone
    )
  }

  private static func metricRollupCells(
    kind: HealthObservationKind,
    endedAt: Date,
    timeZone: TimeZone
  ) -> Set<DailyRollupCell> {
    guard kind != .sleepAnalysis else { return [] }
    let date = logicalDate(for: endedAt, timeZone: timeZone)
    let cells: Set<DailyRollupCell> = [DailyRollupCell(logicalDate: date, kind: kind)]
    return cells
  }

  private static func statisticsRangePartition(
    for query: HealthArchiveStatisticsQuery,
    timeZone: TimeZone
  ) -> StatisticsRangePartition {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let startDay = calendar.startOfDay(for: query.startsAt)
    let endDay = calendar.startOfDay(for: query.endsAt)
    guard let nextStartDay = calendar.date(byAdding: .day, value: 1, to: startDay) else {
      return StatisticsRangePartition(
        completeStartLogicalDate: nil,
        completeEndLogicalDate: nil,
        partialIntervals: [
          ObservationInterval(
            startsAt: query.startsAt,
            endsAt: query.endsAt,
            includesEnd: true
          )
        ]
      )
    }
    let completeStart = query.startsAt == startDay ? startDay : nextStartDay
    guard completeStart < endDay else {
      return StatisticsRangePartition(
        completeStartLogicalDate: nil,
        completeEndLogicalDate: nil,
        partialIntervals: [
          ObservationInterval(
            startsAt: query.startsAt,
            endsAt: query.endsAt,
            includesEnd: true
          )
        ]
      )
    }
    var partialIntervals: [ObservationInterval] = []
    if query.startsAt < completeStart {
      partialIntervals.append(
        ObservationInterval(
          startsAt: query.startsAt,
          endsAt: completeStart,
          includesEnd: false
        ))
    }
    partialIntervals.append(
      ObservationInterval(
        startsAt: endDay,
        endsAt: query.endsAt,
        includesEnd: true
      ))
    return StatisticsRangePartition(
      completeStartLogicalDate: logicalDate(for: completeStart, timeZone: timeZone),
      completeEndLogicalDate: logicalDate(for: endDay, timeZone: timeZone),
      partialIntervals: partialIntervals
    )
  }

  private static func logicalDate(for date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d",
      components.year ?? 0,
      components.month ?? 0,
      components.day ?? 0
    )
  }

  private static func localDayBounds(
    _ logicalDate: String,
    timeZone: TimeZone
  ) -> Range<Date>? {
    let fields = logicalDate.split(separator: "-").compactMap { Int($0) }
    guard fields.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard
      let start = calendar.date(
        from: DateComponents(
          year: fields[0],
          month: fields[1],
          day: fields[2]
        )), let end = calendar.date(byAdding: .day, value: 1, to: start)
    else { return nil }
    return start..<end
  }

  private static func maxOptionalDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case (.none, .none): nil
    case (.some(let value), .none), (.none, .some(let value)): value
    case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
    }
  }

}
