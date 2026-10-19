import DaydayCore
import Foundation
import Testing
@testable import DaydayCapture

struct InputAggregationAccumulatorTests {
    @Test
    func publicOutputContainsTotalsWithoutRawEventShapeOrKeyApplicationLinkage() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        let firstApplication = application("AAAAAAAA-0000-0000-0000-000000000001")
        let secondApplication = application("BBBBBBBB-0000-0000-0000-000000000002")

        try await accumulator.record(
            key(at: "2026-08-01T00:10:00Z", code: 42, application: firstApplication),
            disposition: .allowed
        )
        try await accumulator.record(
            key(at: "2026-08-01T00:20:00Z", code: 43, application: secondApplication),
            disposition: .allowed
        )

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        let encoded = try JSONEncoder().encode(aggregate)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(aggregate.physicalKeyCounts == [
            PhysicalKeyCount(hardwareKeyCode: 42, count: 1),
            PhysicalKeyCount(hardwareKeyCode: 43, count: 1),
        ])
        #expect(aggregate.applicationTotals.map(\.keyCount) == [1, 1])
        for forbidden in [
            "occurredAt", "normalizedX", "normalizedY", "location", "action",
            "character", "text", "sequence", "modifier", "keyApplication"
        ] {
            #expect(!json.contains(forbidden))
        }
    }

    @Test
    func newlyWrittenAggregatesKeepTheRetiredCharacterFieldAtZero() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        try await accumulator.record(
            key(at: "2026-08-01T00:10:00Z", code: 42), disposition: .allowed
        )

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        let json = try #require(String(data: JSONEncoder().encode(aggregate), encoding: .utf8))

        #expect(aggregate.committedCharacterCount == 0)
        #expect(json.contains("\"committedCharacterCount\":0"))
    }

    @Test
    func openCheckpointKeepsTheHourOpenAndContainsOnlyClosedAggregateData() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        try await accumulator.record(
            key(at: "2026-08-01T00:10:00Z", code: 42), disposition: .allowed
        )
        let checkpoints = try await accumulator.openCheckpoints(
            at: instant("2026-08-01T00:10:30Z")
        )
        let checkpoint = try #require(checkpoints.first)
        #expect(checkpoint.revision > 0)
        #expect(checkpoint.aggregate.physicalKeyCounts == [
            PhysicalKeyCount(hardwareKeyCode: 42, count: 1)
        ])
        try await accumulator.record(
            key(at: "2026-08-01T00:11:00Z", code: 42), disposition: .allowed
        )
        let next = try #require(try await accumulator.openCheckpoints(
            at: instant("2026-08-01T00:11:30Z")
        ).first)
        #expect(next.aggregate.id == checkpoint.aggregate.id)
        #expect(next.revision > checkpoint.revision)
        #expect(next.aggregate.physicalKeyCounts.first?.count == 2)
    }

    @Test
    func detectedInteractionDurationIncludesOnlyNearbyAdmittedInput() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        for value in [
            "2026-08-01T00:00:00Z",
            "2026-08-01T00:00:45Z",
            "2026-08-01T00:02:00Z",
            "2026-08-01T00:02:30Z",
        ] {
            try await accumulator.record(
                key(at: value, code: 42),
                disposition: .allowed
            )
        }

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )

        // 00:00:00–00:00:45 and 00:02:00–00:02:30 are provable input
        // clusters. The 75-second silent gap must not be represented as active.
        #expect(aggregate.includedDurationMilliseconds == 75_000)
    }

    @Test
    func completedBucketStaysRecoverableUntilDurableFinalizationSealsIt() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        try await accumulator.record(
            key(at: "2026-08-01T00:10:00Z", code: 42), disposition: .allowed
        )
        let completed = try await accumulator.completedAggregates(
            endingBefore: instant("2026-08-01T01:00:00Z")
        )
        #expect(completed.count == 1)
        #expect((await accumulator.snapshot()).pendingPeriods.count == 1)
        try await accumulator.seal(completed)
        #expect((try await accumulator.completedAggregates(
            endingBefore: instant("2026-08-01T01:00:00Z")
        )).isEmpty)
    }

    @Test
    func flushIsIdempotentAndAnExactHourBoundaryStartsANewBucket() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        try await accumulator.record(
            key(at: "2026-08-01T00:59:59Z", code: 10),
            disposition: .allowed
        )
        try await accumulator.record(
            key(at: "2026-08-01T01:00:00Z", code: 11),
            disposition: .allowed
        )
        try await accumulator.record(
            try TransientInputCoverageSample(
                startedAt: instant("2026-08-01T00:59:59Z"),
                endedAt: instant("2026-08-01T01:00:01Z")
            ),
            disposition: .allowed
        )

        let firstFlush = try await accumulator.flush(
            completedBefore: instant("2026-08-01T01:00:00Z")
        )
        let duplicateFlush = try await accumulator.flush(
            completedBefore: instant("2026-08-01T01:00:00Z")
        )
        let pending = await accumulator.snapshot()

        #expect(firstFlush.count == 1)
        #expect(firstFlush.first?.period.start == instant("2026-08-01T00:00:00Z"))
        #expect(firstFlush.first?.includedDurationMilliseconds == 1_000)
        #expect(duplicateFlush.isEmpty)
        #expect(pending.pendingPeriods.map(\.start) == [instant("2026-08-01T01:00:00Z")])

        do {
            try await accumulator.record(
                key(at: "2026-08-01T00:30:00Z", code: 12),
                disposition: .allowed
            )
            Issue.record("A sealed hour accepted a late raw sample")
        } catch let error as InputAggregationAccumulatorError {
            #expect(error == .bucketAlreadyFlushed)
        }
    }

    @Test
    func displayTopologyAndApplicationSwitchesRemainSeparateAggregateDimensions() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        let displayID = display("CCCCCCCC-0000-0000-0000-000000000003")
        let otherDisplayID = display("DDDDDDDD-0000-0000-0000-000000000004")
        let firstApp = application("EEEEEEEE-0000-0000-0000-000000000005")
        let secondApp = application("FFFFFFFF-0000-0000-0000-000000000006")
        let dwellOnlyApp = application("ABABABAB-0000-0000-0000-000000000007")
        let location = try TransientNormalizedPointerLocation(x: 0.25, y: 0.75)

        try await accumulator.record(
            try pointer(
                display: DisplayContext(id: displayID, topologyRevision: 1),
                application: firstApp,
                location: location,
                action: .click(.left)
            ),
            disposition: .allowed
        )
        try await accumulator.record(
            try pointer(
                display: DisplayContext(id: displayID, topologyRevision: 2),
                application: firstApp,
                location: location,
                action: .movement(distanceMilliPoints: 500)
            ),
            disposition: .allowed
        )
        try await accumulator.record(
            try pointer(
                display: DisplayContext(id: otherDisplayID, topologyRevision: 1),
                application: secondApp,
                location: location,
                action: .scroll(.down, magnitude: 9, eventCount: 1)
            ),
            disposition: .allowed
        )
        try await accumulator.record(
            try pointer(
                display: DisplayContext(id: otherDisplayID, topologyRevision: 1),
                application: dwellOnlyApp,
                location: location,
                action: .dwell(milliseconds: 250)
            ),
            disposition: .allowed
        )

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )

        #expect(aggregate.displays.count == 3)
        #expect(Set(aggregate.displays.map(\.display)) == [
            DisplayContext(id: displayID, topologyRevision: 1),
            DisplayContext(id: displayID, topologyRevision: 2),
            DisplayContext(id: otherDisplayID, topologyRevision: 1),
        ])
        #expect(aggregate.applicationTotals.count == 2)
        #expect(!aggregate.applicationTotals.contains {
            $0.applicationIdentifier == dwellOnlyApp
        })
        #expect(aggregate.applicationTotals.first {
            $0.applicationIdentifier == firstApp
        }?.pointer.estimatedDistanceMilliPoints == 500)
        #expect(aggregate.applicationTotals.first {
            $0.applicationIdentifier == secondApp
        }?.pointer.scroll.down == 9)
    }

    @Test
    func everyNonAllowedDispositionContributesExactlyZero() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        let excludedOnly = try makeAccumulator(timeZoneIdentifier: "UTC")

        try await accumulator.record(
            key(at: "2026-08-01T00:10:00Z", code: 42),
            disposition: .allowed
        )
        try await accumulator.record(
            key(at: "2026-08-01T00:11:00Z", code: 42),
            disposition: .excluded(.secureInput)
        )
        try await accumulator.record(
            key(at: "2026-08-01T00:12:00Z", code: 42),
            disposition: .metadataOnly(.globalPause)
        )
        try await accumulator.record(
            try TransientInputCoverageSample(
                startedAt: instant("2026-08-01T00:00:00Z"),
                endedAt: instant("2026-08-01T00:00:05Z")
            ),
            disposition: .allowed
        )
        try await accumulator.record(
            try TransientInputCoverageSample(
                startedAt: instant("2026-08-01T00:00:05Z"),
                endedAt: instant("2026-08-01T00:59:00Z")
            ),
            disposition: .excluded(.screenLocked)
        )
        try await excludedOnly.record(
            key(at: "2026-08-01T00:10:00Z", code: 99),
            disposition: .excluded(.userExclusion)
        )

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        #expect(aggregate.physicalKeyCounts == [
            PhysicalKeyCount(hardwareKeyCode: 42, count: 1)
        ])
        #expect(aggregate.includedDurationMilliseconds == 5_000)
        #expect((await excludedOnly.snapshot()).pendingPeriods.isEmpty)
    }

    @Test
    func coverageUsesIntervalUnionWithinAndAcrossHoursAndRollsBackOnFailure() async throws {
        let withinHour = try makeAccumulator(timeZoneIdentifier: "UTC")
        for (start, end) in [
            ("2026-08-01T00:00:00Z", "2026-08-01T00:30:00Z"),
            ("2026-08-01T00:15:00Z", "2026-08-01T00:45:00Z"),
            ("2026-08-01T00:10:00Z", "2026-08-01T00:20:00Z"),
        ] {
            try await withinHour.record(
                try TransientInputCoverageSample(
                    startedAt: instant(start),
                    endedAt: instant(end)
                ),
                disposition: .allowed
            )
        }
        let withinAggregate = try #require(
            try await withinHour.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        #expect(withinAggregate.includedDurationMilliseconds == 45 * 60 * 1_000)

        let acrossHours = try makeAccumulator(timeZoneIdentifier: "UTC")
        for (start, end) in [
            ("2026-08-01T00:30:00Z", "2026-08-01T01:30:00Z"),
            ("2026-08-01T00:45:00Z", "2026-08-01T01:15:00Z"),
        ] {
            try await acrossHours.record(
                try TransientInputCoverageSample(
                    startedAt: instant(start),
                    endedAt: instant(end)
                ),
                disposition: .allowed
            )
        }
        let acrossAggregates = try await acrossHours.flush(
            completedBefore: instant("2026-08-01T02:00:00Z")
        )
        let actualDurations: [UInt64] = acrossAggregates.map(
            \.includedDurationMilliseconds
        )
        let expectedDurations: [UInt64] = [1_800_000, 1_800_000]
        #expect(actualDurations == expectedDurations)

        let rollback = try makeAccumulator(timeZoneIdentifier: "UTC")
        _ = try await rollback.flush(
            completedBefore: instant("2026-08-01T01:00:00Z")
        )
        try await rollback.record(
            key(at: "2026-08-01T01:10:00Z", code: 7),
            disposition: .allowed
        )
        do {
            try await rollback.record(
                try TransientInputCoverageSample(
                    startedAt: instant("2026-08-01T00:30:00Z"),
                    endedAt: instant("2026-08-01T01:30:00Z")
                ),
                disposition: .allowed
            )
            Issue.record("Coverage spanning a sealed bucket was accepted")
        } catch let error as InputAggregationAccumulatorError {
            #expect(error == .bucketAlreadyFlushed)
        }
        let rollbackAggregate = try #require(
            try await rollback.flush(
                completedBefore: instant("2026-08-01T02:00:00Z")
            ).first
        )
        #expect(rollbackAggregate.includedDurationMilliseconds == 0)
    }

    @Test
    func civilHourBucketingDistinguishesDSTRepeatAndSkipsDSTGap() async throws {
        let repeated = try makeAccumulator(timeZoneIdentifier: "America/Los_Angeles")
        try await repeated.record(
            key(at: "2026-11-01T08:30:00Z", code: 1),
            disposition: .allowed
        )
        try await repeated.record(
            key(at: "2026-11-01T09:30:00Z", code: 2),
            disposition: .allowed
        )
        let repeatedHours = try await repeated.flush(
            completedBefore: instant("2026-11-01T10:00:00Z")
        )

        #expect(repeatedHours.map(\.period.start) == [
            instant("2026-11-01T08:00:00Z"),
            instant("2026-11-01T09:00:00Z"),
        ])
        #expect(repeatedHours.allSatisfy {
            $0.period.end.timeIntervalSince($0.period.start) == 3_600
        })

        let skipped = try makeAccumulator(timeZoneIdentifier: "America/Los_Angeles")
        try await skipped.record(
            key(at: "2026-03-08T09:30:00Z", code: 3),
            disposition: .allowed
        )
        try await skipped.record(
            key(at: "2026-03-08T10:30:00Z", code: 4),
            disposition: .allowed
        )
        let skippedHours = try await skipped.flush(
            completedBefore: instant("2026-03-08T11:00:00Z")
        )
        #expect(skippedHours.map(\.period.start) == [
            instant("2026-03-08T09:00:00Z"),
            instant("2026-03-08T10:00:00Z"),
        ])

        let lordHoweFall = try makeAccumulator(
            timeZoneIdentifier: "Australia/Lord_Howe"
        )
        for timestamp in [
            "2026-04-04T14:30:00Z",
            "2026-04-04T15:15:00Z",
            "2026-04-04T15:45:00Z",
        ] {
            try await lordHoweFall.record(
                key(at: timestamp, code: 5),
                disposition: .allowed
            )
        }
        let lordHoweFallHours = try await lordHoweFall.flush(
            completedBefore: instant("2026-04-04T16:30:00Z")
        )
        #expect(lordHoweFallHours.map(\.period.start) == [
            instant("2026-04-04T14:00:00Z"),
            instant("2026-04-04T15:00:00Z"),
            instant("2026-04-04T15:30:00Z"),
        ])
        #expect(lordHoweFallHours.map(\.period.end) == [
            instant("2026-04-04T15:00:00Z"),
            instant("2026-04-04T15:30:00Z"),
            instant("2026-04-04T16:30:00Z"),
        ])
        #expect(zip(lordHoweFallHours, lordHoweFallHours.dropFirst()).allSatisfy {
            $0.period.end == $1.period.start
        })

        let lordHoweSpring = try makeAccumulator(
            timeZoneIdentifier: "Australia/Lord_Howe"
        )
        for timestamp in [
            "2026-10-03T15:15:00Z",
            "2026-10-03T15:45:00Z",
            "2026-10-03T16:15:00Z",
        ] {
            try await lordHoweSpring.record(
                key(at: timestamp, code: 6),
                disposition: .allowed
            )
        }
        let lordHoweSpringHours = try await lordHoweSpring.flush(
            completedBefore: instant("2026-10-03T17:00:00Z")
        )
        #expect(lordHoweSpringHours.map(\.period.start) == [
            instant("2026-10-03T14:30:00Z"),
            instant("2026-10-03T15:30:00Z"),
            instant("2026-10-03T16:00:00Z"),
        ])
        #expect(lordHoweSpringHours.map(\.period.end) == [
            instant("2026-10-03T15:30:00Z"),
            instant("2026-10-03T16:00:00Z"),
            instant("2026-10-03T17:00:00Z"),
        ])
        #expect(zip(lordHoweSpringHours, lordHoweSpringHours.dropFirst()).allSatisfy {
            $0.period.end == $1.period.start
        })
    }

    @Test
    func overflowFailsClosedWithoutPartiallyMutatingTheBucket() async throws {
        let accumulator = try makeAccumulator(timeZoneIdentifier: "UTC")
        let display = DisplayContext(
            id: display("12121212-0000-0000-0000-000000000012"),
            topologyRevision: 7
        )
        let app = application("13131313-0000-0000-0000-000000000013")
        let location = try TransientNormalizedPointerLocation(x: 0.5, y: 0.5)

        try await accumulator.record(
            try pointer(
                display: display,
                application: app,
                location: location,
                action: .movement(distanceMilliPoints: .max)
            ),
            disposition: .allowed
        )
        do {
            try await accumulator.record(
                try pointer(
                    display: display,
                    application: app,
                    location: location,
                    action: .movement(distanceMilliPoints: 1)
                ),
                disposition: .allowed
            )
            Issue.record("Overflowing input was accepted")
        } catch let error as InputAggregationAccumulatorError {
            #expect(error == .unsignedOverflow)
        }

        let aggregate = try #require(
            try await accumulator.flush(
                completedBefore: instant("2026-08-01T01:00:00Z")
            ).first
        )
        #expect(aggregate.displays.first?.pointer.estimatedDistanceMilliPoints == .max)
        #expect(aggregate.applicationTotals.first?.pointer.estimatedDistanceMilliPoints == .max)
    }

    private func makeAccumulator(
        timeZoneIdentifier: String
    ) throws -> InputAggregationAccumulator {
        InputAggregationAccumulator(
            configuration: try InputAggregationAccumulatorConfiguration(
                timeZoneIdentifier: timeZoneIdentifier,
                gridRows: 8,
                gridColumns: 8,
                collectorVersion: "input-1",
                defaultLayoutVersion: "ansi-1"
            )
        )
    }

    private func key(
        at timestamp: String,
        code: UInt16,
        application: ApplicationIdentifier? = nil
    ) throws -> TransientPhysicalKeySample {
        try TransientPhysicalKeySample(
            occurredAt: instant(timestamp),
            hardwareKeyCode: code,
            applicationIdentifier: application,
            layoutVersion: "ansi-1"
        )
    }

    private func pointer(
        display: DisplayContext,
        application: ApplicationIdentifier?,
        location: TransientNormalizedPointerLocation,
        action: TransientPointerAction
    ) throws -> TransientPointerSample {
        try TransientPointerSample(
            occurredAt: instant("2026-08-01T00:30:00Z"),
            display: display,
            applicationIdentifier: application,
            location: location,
            action: action
        )
    }

    private func application(_ value: String) -> ApplicationIdentifier {
        ApplicationIdentifier(rawValue: UUID(uuidString: value)!)
    }

    private func display(_ value: String) -> DisplayID {
        DisplayID(rawValue: UUID(uuidString: value)!)
    }

    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
