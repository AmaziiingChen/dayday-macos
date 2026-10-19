import Foundation
import Testing
@testable import DaydayCore

struct InputAggregateTests {
    @Test
    func aggregateShapeRoundTripsWithoutReplayableInputFields() throws {
        let aggregate = try makeAggregate(
            keyCount: 12,
            appKeyCount: 9,
            displayRevision: 3,
            gridCell: NormalizedGridCell(
                row: 2,
                column: 4,
                clicks: ClickCounts(left: 2, right: 1),
                dwellMilliseconds: 4_000
            )
        )

        let data = try JSONEncoder().encode(aggregate)
        let decoded = try JSONDecoder().decode(InputAggregate.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded == aggregate)
        #expect(json.contains("committedCharacterCount"))
        #expect(!json.contains("rawCharacter"))
        #expect(!json.contains("text"))
        #expect(!json.contains("timestamp"))
        #expect(!json.contains("sequence"))
        #expect(!json.contains("coordinate"))
        #expect(!json.contains("path"))
        #expect(!json.contains("perKeyPerApplication"))
        #expect(decoded.applicationTotals.first?.keyCount == 9)
        #expect(decoded.physicalKeyCounts.first?.hardwareKeyCode == 42)
    }

    @Test
    func legacyAggregateWithoutCommittedCharacterCountDecodesAsZero() throws {
        let aggregate = try makeAggregate(keyCount: 1, committedCharacterCount: 7)
        let legacy = try corruptedEncoding(of: aggregate) { root in
            root.removeValue(forKey: "committedCharacterCount")
        }

        let decoded = try JSONDecoder().decode(InputAggregate.self, from: legacy)
        #expect(decoded.committedCharacterCount == 0)
    }

    @Test
    func legacyAggregateWithoutScrollEventCountsDecodesAsZero() throws {
        let aggregate = try makeAggregate(scrollUp: 7, scrollDown: 3)
        let legacy = try corruptedEncoding(of: aggregate) { root in
            for collectionKey in ["displays", "applicationTotals"] {
                var values = try #require(root[collectionKey] as? [[String: Any]])
                for index in values.indices {
                    var pointer = try #require(values[index]["pointer"] as? [String: Any])
                    pointer.removeValue(forKey: "scrollEventCount")
                    values[index]["pointer"] = pointer
                }
                root[collectionKey] = values
            }
        }

        let decoded = try JSONDecoder().decode(InputAggregate.self, from: legacy)
        #expect(decoded.displays.first?.pointer.scrollEventCount == 0)
        #expect(decoded.applicationTotals.first?.pointer.scrollEventCount == 0)
        #expect(decoded.displays.first?.pointer.scroll.up == 7)
    }

    @Test
    func periodsRespectCivilHourDayAndDSTBoundaries() throws {
        let springDay = try InputAggregatePeriod(
            start: instant("2026-03-08T10:00:00Z"),
            end: instant("2026-03-09T09:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "America/Los_Angeles",
            workdayBoundaryHour: 2
        )
        let fallDay = try InputAggregatePeriod(
            start: instant("2026-11-01T08:00:00Z"),
            end: instant("2026-11-02T09:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "America/Los_Angeles",
            workdayBoundaryHour: 1
        )

        #expect(springDay.end.timeIntervalSince(springDay.start) == 23 * 3_600)
        #expect(fallDay.end.timeIntervalSince(fallDay.start) == 25 * 3_600)
        #expect(springDay.workdayBoundaryHour == 2)
        #expect(fallDay.workdayBoundaryHour == 1)
        #expect(throws: InputAggregatePeriod.ValidationError.invalidHourlyBoundary) {
            try InputAggregatePeriod(
                start: instant("2026-08-01T00:00:00Z"),
                end: instant("2026-08-01T02:00:00Z"),
                granularity: .hour,
                timeZoneIdentifier: "Asia/Shanghai"
            )
        }
        #expect(throws: InputAggregatePeriod.ValidationError.boundaryNotAligned) {
            try InputAggregatePeriod(
                start: instant("2026-08-01T00:00:01Z"),
                end: instant("2026-08-01T01:00:01Z"),
                granularity: .hour,
                timeZoneIdentifier: "Asia/Shanghai"
            )
        }
    }

    @Test
    func lordHoweSubHourDSTUsesDisjointPartitionsAndDailyBoundaries() throws {
        let zone = "Australia/Lord_Howe"
        let fallPeriods = try [
            "2026-04-04T14:30:00Z",
            "2026-04-04T15:15:00Z",
            "2026-04-04T15:45:00Z",
        ].map {
            try InputAggregationPolicy.hourlyPeriod(
                containing: instant($0),
                timeZoneIdentifier: zone
            )
        }
        #expect(fallPeriods.map(\.start) == [
            instant("2026-04-04T14:00:00Z"),
            instant("2026-04-04T15:00:00Z"),
            instant("2026-04-04T15:30:00Z"),
        ])
        #expect(fallPeriods.map(\.end) == [
            instant("2026-04-04T15:00:00Z"),
            instant("2026-04-04T15:30:00Z"),
            instant("2026-04-04T16:30:00Z"),
        ])

        let springPeriods = try [
            "2026-10-03T15:15:00Z",
            "2026-10-03T15:45:00Z",
            "2026-10-03T16:15:00Z",
        ].map {
            try InputAggregationPolicy.hourlyPeriod(
                containing: instant($0),
                timeZoneIdentifier: zone
            )
        }
        #expect(springPeriods.map(\.start) == [
            instant("2026-10-03T14:30:00Z"),
            instant("2026-10-03T15:30:00Z"),
            instant("2026-10-03T16:00:00Z"),
        ])
        #expect(springPeriods.map(\.end) == [
            instant("2026-10-03T15:30:00Z"),
            instant("2026-10-03T16:00:00Z"),
            instant("2026-10-03T17:00:00Z"),
        ])
        for periods in [fallPeriods, springPeriods] {
            #expect(zip(periods, periods.dropFirst()).allSatisfy {
                $0.end == $1.start
            })
        }

        let springDay = try InputAggregatePeriod(
            start: instant("2026-10-03T15:30:00Z"),
            end: instant("2026-10-04T15:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: zone,
            workdayBoundaryHour: 2
        )
        let fallDay = try InputAggregatePeriod(
            start: instant("2026-04-03T15:00:00Z"),
            end: instant("2026-04-04T15:30:00Z"),
            granularity: .day,
            timeZoneIdentifier: zone,
            workdayBoundaryHour: 2
        )

        #expect(springDay.end.timeIntervalSince(springDay.start) == 23.5 * 3_600)
        #expect(fallDay.end.timeIntervalSince(fallDay.start) == 24.5 * 3_600)

        let rollupDay = try InputAggregatePeriod(
            start: instant("2026-04-04T13:00:00Z"),
            end: instant("2026-04-05T13:30:00Z"),
            granularity: .day,
            timeZoneIdentifier: zone,
            workdayBoundaryHour: 0
        )
        let rollup = try InputAggregationPolicy.makeDailyRollup(
            period: rollupDay,
            hourly: try fallPeriods.map { try makeAggregate(period: $0, keyCount: 1) }
        )
        #expect(rollup.dailyAggregate.physicalKeyCounts.first?.count == 3)

        #expect(throws: InputAggregatePeriod.ValidationError.boundaryNotAligned) {
            try InputAggregatePeriod(
                start: instant("2026-04-04T14:30:00Z"),
                end: instant("2026-04-04T15:30:00Z"),
                granularity: .hour,
                timeZoneIdentifier: zone
            )
        }
    }

    @Test
    func canonicalPartitionsCoverDSTDaysExactlyOnce() throws {
        for (zone, start, end) in [
            (
                "Australia/Lord_Howe",
                "2026-04-04T13:00:00Z",
                "2026-04-05T13:30:00Z"
            ),
            (
                "Australia/Lord_Howe",
                "2026-10-03T13:30:00Z",
                "2026-10-04T13:00:00Z"
            ),
            (
                "America/Los_Angeles",
                "2026-03-08T08:00:00Z",
                "2026-03-09T07:00:00Z"
            ),
            (
                "America/Los_Angeles",
                "2026-11-01T07:00:00Z",
                "2026-11-02T08:00:00Z"
            ),
        ] {
            let dayStart = instant(start)
            let dayEnd = instant(end)
            var cursor = dayStart
            var coveredDuration: TimeInterval = 0
            while cursor < dayEnd {
                let period = try InputAggregationPolicy.hourlyPeriod(
                    containing: cursor,
                    timeZoneIdentifier: zone
                )
                #expect(period.start == cursor)
                #expect(period.end > period.start)
                #expect(period.end <= dayEnd)
                coveredDuration += period.end.timeIntervalSince(period.start)
                cursor = period.end
            }
            #expect(cursor == dayEnd)
            #expect(coveredDuration == dayEnd.timeIntervalSince(dayStart))
        }
    }

    @Test
    func dailyPeriodRequiresTheConfiguredBoundaryInsteadOfInferringShiftedHour() {
        #expect(throws: InputAggregatePeriod.ValidationError.missingWorkdayBoundaryHour) {
            try InputAggregatePeriod(
                start: instant("2026-03-08T10:00:00Z"),
                end: instant("2026-03-09T09:00:00Z"),
                granularity: .day,
                timeZoneIdentifier: "America/Los_Angeles"
            )
        }
        #expect(throws: InputAggregatePeriod.ValidationError.invalidDailyBoundary) {
            try InputAggregatePeriod(
                start: instant("2026-03-08T10:00:00Z"),
                end: instant("2026-03-09T10:00:00Z"),
                granularity: .day,
                timeZoneIdentifier: "America/Los_Angeles",
                workdayBoundaryHour: 2
            )
        }
    }

    @Test
    func normalizedGridRejectsHighResolutionOutOfRangeAndDuplicateCells() {
        #expect(throws: NormalizedDisplayGrid.ValidationError.invalidDimensions(
            rows: 129,
            columns: 10
        )) {
            try NormalizedDisplayGrid(rows: 129, columns: 10, cells: [])
        }
        #expect(throws: NormalizedDisplayGrid.ValidationError.cellOutOfRange(
            row: 10,
            column: 0
        )) {
            try NormalizedDisplayGrid(
                rows: 10,
                columns: 10,
                cells: [NormalizedGridCell(row: 10, column: 0)]
            )
        }
        #expect(throws: NormalizedDisplayGrid.ValidationError.duplicateCell(
            row: 1,
            column: 1
        )) {
            try NormalizedDisplayGrid(
                rows: 10,
                columns: 10,
                cells: [
                    NormalizedGridCell(row: 1, column: 1),
                    NormalizedGridCell(row: 1, column: 1)
                ]
            )
        }
    }

    @Test
    func mergeIsAssociativeAndCanonical() throws {
        let id = InputAggregateID(rawValue: try #require(
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")
        ))
        let a = try makeAggregate(
            id: id,
            keyCount: 1,
            appKeyCount: 2,
            collectorVersions: ["2.0", "1.0"],
            layoutVersions: ["ansi"]
        )
        let b = try makeAggregate(
            id: id,
            keyCount: 3,
            appKeyCount: 5,
            collectorVersions: ["3.0"],
            layoutVersions: ["iso"]
        )
        let c = try makeAggregate(
            id: id,
            keyCount: 7,
            appKeyCount: 11,
            collectorVersions: ["1.0"],
            layoutVersions: ["ansi"]
        )

        let left = try InputAggregationPolicy.merge(
            InputAggregationPolicy.merge(a, b),
            c
        )
        let right = try InputAggregationPolicy.merge(
            a,
            InputAggregationPolicy.merge(b, c)
        )

        #expect(left == right)
        #expect(left.physicalKeyCounts == [PhysicalKeyCount(hardwareKeyCode: 42, count: 11)])
        #expect(left.applicationTotals.first?.keyCount == 18)
        #expect(left.collectorVersions == ["1.0", "2.0", "3.0"])
        #expect(left.layoutVersions == ["ansi", "iso"])
    }

    @Test
    func mergeRejectsUnsignedOverflowIncludingDirectionalScroll() throws {
        let id = InputAggregateID()
        let maxKey = try makeAggregate(id: id, keyCount: .max)
        let oneKey = try makeAggregate(id: id, keyCount: 1)
        #expect(throws: InputAggregationPolicy.AggregationError.unsignedOverflow) {
            try InputAggregationPolicy.merge(maxKey, oneKey)
        }

        let maxScroll = try makeAggregate(id: id, scrollDown: .max)
        let oneScroll = try makeAggregate(id: id, scrollDown: 1)
        #expect(throws: InputAggregationPolicy.AggregationError.unsignedOverflow) {
            try InputAggregationPolicy.merge(maxScroll, oneScroll)
        }
    }

    @Test
    func directionalScrollMergeIsAssociativeWithoutSignedCancellation() throws {
        let id = InputAggregateID()
        let a = try makeAggregate(id: id, scrollUp: 7, scrollDown: 2)
        let b = try makeAggregate(id: id, scrollUp: 1, scrollDown: 9)
        let c = try makeAggregate(id: id, scrollUp: 4, scrollDown: 3)

        let left = try InputAggregationPolicy.merge(InputAggregationPolicy.merge(a, b), c)
        let right = try InputAggregationPolicy.merge(a, InputAggregationPolicy.merge(b, c))

        #expect(left == right)
        #expect(left.applicationTotals.first?.pointer.scroll == ScrollTotals(up: 12, down: 14))
    }

    @Test
    func applicationIdentifierRejectsFreeFormContextAndFailsClosedOnDecode() throws {
        for value in [
            "Quarterly report — draft",
            "https://example.com/private?token=secret",
            "Password field",
            "com.example.window title"
        ] {
            let encoded = Data(#"{"applicationIdentifier":"\#(value)","keyCount":1,"pointer":{"clicks":{"left":0,"right":0,"other":0},"scroll":{"up":0,"down":0,"left":0,"right":0},"estimatedDistanceMilliPoints":0}}"#.utf8)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(ApplicationInputTotals.self, from: encoded)
            }
        }

        let encoded = Data(#"{"applicationIdentifier":"private document body","keyCount":1,"pointer":{"clicks":{"left":0,"right":0,"other":0},"scroll":{"up":0,"down":0,"left":0,"right":0},"estimatedDistanceMilliPoints":0}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ApplicationInputTotals.self, from: encoded)
        }
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(ApplicationIdentifier(rawValue: id).rawValue == id)
    }

    @Test
    func privacyExclusionsContributeExactlyZero() throws {
        let accumulator = try makeAggregate(keyCount: 4, includedMilliseconds: 5_000)
        let incompatibleCandidate = try makeAggregate(
            id: InputAggregateID(),
            keyCount: 999,
            includedMilliseconds: 999_000
        )

        let excluded = try InputAggregationPolicy.adding(
            incompatibleCandidate,
            to: accumulator,
            disposition: .excluded(.secureInput)
        )
        let metadataOnly = try InputAggregationPolicy.adding(
            incompatibleCandidate,
            to: accumulator,
            disposition: .metadataOnly(.incognito)
        )

        #expect(excluded == accumulator)
        #expect(metadataOnly == accumulator)
    }

    @Test
    func dailyRollupSupportsTopologyRevisionsAndRequiresExplicitSourceHandling() throws {
        let day = try InputAggregatePeriod(
            start: instant("2026-08-01T00:00:00Z"),
            end: instant("2026-08-02T00:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "UTC",
            workdayBoundaryHour: 0
        )
        let firstPeriod = try hourlyPeriod(start: "2026-08-01T00:00:00Z")
        let secondPeriod = try hourlyPeriod(start: "2026-08-01T01:00:00Z")
        let first = try makeAggregate(
            id: InputAggregateID(rawValue: try #require(
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")
            )),
            period: firstPeriod,
            keyCount: 2,
            displayRevision: 5
        )
        let second = try makeAggregate(
            id: InputAggregateID(rawValue: try #require(
                UUID(uuidString: "20000000-0000-0000-0000-000000000002")
            )),
            period: secondPeriod,
            keyCount: 3,
            displayRevision: 6
        )

        let plan = try InputAggregationPolicy.makeDailyRollup(
            period: day,
            hourly: [second, first]
        )

        #expect(plan.dailyAggregate.period.granularity == .day)
        #expect(plan.dailyAggregate.physicalKeyCounts.first?.count == 5)
        #expect(plan.dailyAggregate.displays.map(\DisplayInputAggregate.display.topologyRevision) == [5, 6])
        #expect(plan.sourceHourlyAggregateIDs == [first.id, second.id])
        #expect(first.period.granularity == .hour)
        #expect(second.period.granularity == .hour)
    }

    @Test
    func dailyRollupRejectsOverlapDuplicatesAndCrossTimeZoneSources() throws {
        let day = try InputAggregatePeriod(
            start: instant("2026-08-01T00:00:00Z"),
            end: instant("2026-08-02T00:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "UTC",
            workdayBoundaryHour: 0
        )
        let id = InputAggregateID()
        let source = try makeAggregate(id: id, period: hourlyPeriod(start: "2026-08-01T00:00:00Z"))
        #expect(throws: InputAggregationPolicy.AggregationError.duplicateSource(id)) {
            try InputAggregationPolicy.makeDailyRollup(period: day, hourly: [source, source])
        }
        #expect(throws: InputAggregationPolicy.AggregationError.outputCollidesWithSource(id)) {
            try InputAggregationPolicy.makeDailyRollup(id: id, period: day, hourly: [source])
        }
        let distinctIDSamePeriod = try makeAggregate(
            id: InputAggregateID(),
            period: source.period
        )
        #expect(throws: InputAggregationPolicy.AggregationError.overlappingHourlyPeriods) {
            try InputAggregationPolicy.makeDailyRollup(
                period: day,
                hourly: [source, distinctIDSamePeriod]
            )
        }

        let shanghaiHour = try InputAggregatePeriod(
            start: instant("2026-08-01T00:00:00Z"),
            end: instant("2026-08-01T01:00:00Z"),
            granularity: .hour,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let wrongZone = try makeAggregate(period: shanghaiHour)
        #expect(throws: InputAggregationPolicy.AggregationError.sourceTimeZoneMismatch) {
            try InputAggregationPolicy.makeDailyRollup(period: day, hourly: [wrongZone])
        }
    }

    @Test
    func retentionCutoffUsesWorkdayBoundaryAndCivilDays() throws {
        let reference = instant("2026-08-01T12:30:00Z")
        let cutoff = try InputAggregationPolicy.hourlyRollupCutoff(
            relativeTo: reference,
            timeZoneIdentifier: "Asia/Shanghai",
            workdayBoundaryHour: 4
        )
        // 04:00 local on 2026-02-02 is 20:00 UTC on the preceding date.
        let expected = instant("2026-02-01T20:00:00Z")
        #expect(cutoff == expected)

        let oldHour = try makeAggregate(period: hourlyPeriod(start: "2026-02-01T19:00:00Z"))
        let currentHour = try makeAggregate(period: hourlyPeriod(start: "2026-02-01T20:00:00Z"))
        #expect(InputAggregationPolicy.isEligibleForDailyRollup(oldHour, cutoff: cutoff))
        #expect(!InputAggregationPolicy.isEligibleForDailyRollup(currentHour, cutoff: cutoff))
    }

    @Test
    func retentionCutoffReappliesBoundaryAcrossDSTGapAndRepeat() throws {
        let springCutoff = try InputAggregationPolicy.hourlyRollupCutoff(
            relativeTo: instant("2026-03-10T18:00:00Z"),
            timeZoneIdentifier: "America/Los_Angeles",
            workdayBoundaryHour: 2,
            retentionDays: 2
        )
        #expect(springCutoff == instant("2026-03-08T10:00:00Z"))

        let fallCutoff = try InputAggregationPolicy.hourlyRollupCutoff(
            relativeTo: instant("2026-11-03T18:00:00Z"),
            timeZoneIdentifier: "America/Los_Angeles",
            workdayBoundaryHour: 1,
            retentionDays: 2
        )
        #expect(fallCutoff == instant("2026-11-01T08:00:00Z"))
    }

    @Test
    func dailyRollupIDIsDeterministicAndDistinctAcrossDays() throws {
        let day = try InputAggregatePeriod(
            start: instant("2026-08-01T04:00:00Z"),
            end: instant("2026-08-02T04:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "UTC",
            workdayBoundaryHour: 4
        )
        let again = try InputAggregatePeriod(
            start: instant("2026-08-01T04:00:00Z"),
            end: instant("2026-08-02T04:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "UTC",
            workdayBoundaryHour: 4
        )
        #expect(try InputAggregationPolicy.dailyRollupID(for: day)
            == InputAggregationPolicy.dailyRollupID(for: again))

        let nextDay = try InputAggregatePeriod(
            start: instant("2026-08-02T04:00:00Z"),
            end: instant("2026-08-03T04:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "UTC",
            workdayBoundaryHour: 4
        )
        #expect(try InputAggregationPolicy.dailyRollupID(for: day)
            != InputAggregationPolicy.dailyRollupID(for: nextDay))

        let otherZone = try InputAggregatePeriod(
            start: instant("2026-07-31T20:00:00Z"),
            end: instant("2026-08-01T20:00:00Z"),
            granularity: .day,
            timeZoneIdentifier: "Asia/Shanghai",
            workdayBoundaryHour: 4
        )
        #expect(try InputAggregationPolicy.dailyRollupID(for: day)
            != InputAggregationPolicy.dailyRollupID(for: otherZone))

        #expect(throws: InputAggregationPolicy.AggregationError.dailyTargetRequired) {
            _ = try InputAggregationPolicy.dailyRollupID(
                for: try hourlyPeriod(start: "2026-08-01T00:00:00Z")
            )
        }
    }

    @Test
    func dailyRollupPlansGroupHoursByCivilDayAndSkipPartialDays() throws {
        let cutoff = instant("2026-08-01T04:00:00Z")
        // Two complete hours of one civil day ending exactly at the cutoff.
        let first = try makeAggregate(
            id: InputAggregateID(rawValue: try #require(
                UUID(uuidString: "12000000-0000-0000-0000-000000000001")
            )),
            period: hourlyPeriod(start: "2026-07-31T23:00:00Z"),
            keyCount: 2
        )
        let second = try makeAggregate(
            id: InputAggregateID(rawValue: try #require(
                UUID(uuidString: "12000000-0000-0000-0000-000000000002")
            )),
            period: hourlyPeriod(start: "2026-08-01T02:00:00Z"),
            keyCount: 3
        )
        // A third hour whose civil day ends after the cutoff must not roll up.
        let partial = try makeAggregate(
            id: InputAggregateID(rawValue: try #require(
                UUID(uuidString: "12000000-0000-0000-0000-000000000003")
            )),
            period: hourlyPeriod(start: "2026-08-01T05:00:00Z"),
            keyCount: 5
        )

        let plans = try InputAggregationPolicy.dailyRollupPlans(
            for: [partial, first, second],
            cutoff: cutoff,
            workdayBoundaryHour: 4
        )

        #expect(plans.count == 1)
        let plan = try #require(plans.first)
        #expect(plan.dailyAggregate.period.start == instant("2026-07-31T04:00:00Z"))
        #expect(plan.dailyAggregate.period.end == instant("2026-08-01T04:00:00Z"))
        #expect(plan.sourceHourlyAggregateIDs == [first.id, second.id])
        #expect(plan.dailyAggregate.physicalKeyCounts.first?.count == 5)
        let expectedID = try InputAggregationPolicy.dailyRollupID(for: plan.dailyAggregate.period)
        #expect(plan.dailyAggregate.id == expectedID)
    }

    @Test
    func dailyRollupPlansProduceOnePlanPerTimezoneDay() throws {
        let cutoff = instant("2026-08-01T04:00:00Z")
        let utcHour = try makeAggregate(period: hourlyPeriod(start: "2026-07-31T23:00:00Z"))
        let shanghaiPeriod = try InputAggregatePeriod(
            start: instant("2026-07-31T08:00:00Z"),
            end: instant("2026-07-31T09:00:00Z"),
            granularity: .hour,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        let shanghaiHour = try makeAggregate(period: shanghaiPeriod)

        let plans = try InputAggregationPolicy.dailyRollupPlans(
            for: [utcHour, shanghaiHour],
            cutoff: cutoff,
            workdayBoundaryHour: 4
        )
        #expect(plans.count == 2)
        #expect(Set(plans.map { $0.dailyAggregate.period.timeZoneIdentifier })
            == ["UTC", "Asia/Shanghai"])
    }

    @Test
    func aggregateRejectsDuplicateDimensionsAndDurationBeyondBucket() throws {
        let period = try hourlyPeriod(start: "2026-08-01T00:00:00Z")
        #expect(throws: InputAggregate.ValidationError.duplicateHardwareKeyCode(42)) {
            try InputAggregate(
                period: period,
                physicalKeyCounts: [
                    PhysicalKeyCount(hardwareKeyCode: 42, count: 1),
                    PhysicalKeyCount(hardwareKeyCode: 42, count: 2)
                ],
                collectorVersions: ["1"],
                layoutVersions: ["ansi"]
            )
        }
        #expect(throws: InputAggregate.ValidationError.includedDurationExceedsPeriod) {
            try InputAggregate(
                period: period,
                includedDurationMilliseconds: 3_600_001,
                collectorVersions: ["1"],
                layoutVersions: ["ansi"]
            )
        }
    }

    @Test
    func decodingCorruptedPersistenceFailsClosedAcrossAggregateInvariants() throws {
        let aggregate = try makeAggregate(keyCount: 1, appKeyCount: 1)

        let invalidZone = try corruptedEncoding(of: aggregate) { root in
            try mutateDictionary(&root, key: "period") { period in
                period["timeZoneIdentifier"] = "Private/Invented_Zone"
            }
        }
        #expect(throws: InputAggregatePeriod.ValidationError.invalidTimeZoneIdentifier(
            "Private/Invented_Zone"
        )) {
            try JSONDecoder().decode(InputAggregate.self, from: invalidZone)
        }

        let invalidPeriod = try corruptedEncoding(of: aggregate) { root in
            try mutateDictionary(&root, key: "period") { period in
                period["end"] = period["start"]
            }
        }
        #expect(throws: InputAggregatePeriod.ValidationError.endNotAfterStart) {
            try JSONDecoder().decode(InputAggregate.self, from: invalidPeriod)
        }

        let duplicateGridCell = try corruptedEncoding(of: aggregate) { root in
            var displays = try #require(root["displays"] as? [[String: Any]])
            var display = try #require(displays.first)
            var grid = try #require(display["grid"] as? [String: Any])
            var cells = try #require(grid["cells"] as? [[String: Any]])
            cells.append(try #require(cells.first))
            grid["cells"] = cells
            display["grid"] = grid
            displays[0] = display
            root["displays"] = displays
        }
        #expect(throws: NormalizedDisplayGrid.ValidationError.duplicateCell(
            row: 0,
            column: 0
        )) {
            try JSONDecoder().decode(InputAggregate.self, from: duplicateGridCell)
        }

        let duplicateKey = try corruptedEncoding(of: aggregate) { root in
            var keys = try #require(root["physicalKeyCounts"] as? [[String: Any]])
            keys.append(try #require(keys.first))
            root["physicalKeyCounts"] = keys
        }
        #expect(throws: InputAggregate.ValidationError.duplicateHardwareKeyCode(42)) {
            try JSONDecoder().decode(InputAggregate.self, from: duplicateKey)
        }

        let applicationID = try #require(aggregate.applicationTotals.first?.applicationIdentifier)
        let duplicateApplication = try corruptedEncoding(of: aggregate) { root in
            var applications = try #require(
                root["applicationTotals"] as? [[String: Any]]
            )
            applications.append(try #require(applications.first))
            root["applicationTotals"] = applications
        }
        #expect(throws: InputAggregate.ValidationError.duplicateApplicationIdentifier(
            applicationID
        )) {
            try JSONDecoder().decode(InputAggregate.self, from: duplicateApplication)
        }

        let display = try #require(aggregate.displays.first?.display)
        let duplicateDisplay = try corruptedEncoding(of: aggregate) { root in
            var displays = try #require(root["displays"] as? [[String: Any]])
            displays.append(try #require(displays.first))
            root["displays"] = displays
        }
        #expect(throws: InputAggregate.ValidationError.duplicateDisplay(
            display.id,
            topologyRevision: display.topologyRevision
        )) {
            try JSONDecoder().decode(InputAggregate.self, from: duplicateDisplay)
        }

        let invalidVersion = try corruptedEncoding(of: aggregate) { root in
            root["collectorVersions"] = ["contains private prose"]
        }
        #expect(throws: InputAggregate.ValidationError.invalidVersion(
            "contains private prose"
        )) {
            try JSONDecoder().decode(InputAggregate.self, from: invalidVersion)
        }

        let excessiveDuration = try corruptedEncoding(of: aggregate) { root in
            root["includedDurationMilliseconds"] = 3_600_001
        }
        #expect(throws: InputAggregate.ValidationError.includedDurationExceedsPeriod) {
            try JSONDecoder().decode(InputAggregate.self, from: excessiveDuration)
        }
    }

    private func makeAggregate(
        id: InputAggregateID = InputAggregateID(),
        period: InputAggregatePeriod? = nil,
        keyCount: UInt64 = 0,
        committedCharacterCount: UInt64 = 0,
        appKeyCount: UInt64 = 0,
        scrollUp: UInt64 = 0,
        scrollDown: UInt64 = 0,
        includedMilliseconds: UInt64 = 0,
        displayRevision: UInt64 = 1,
        gridCell: NormalizedGridCell? = nil,
        collectorVersions: [String] = ["1.0"],
        layoutVersions: [String] = ["ansi-v1"]
    ) throws -> InputAggregate {
        let displayID = DisplayID(rawValue: try #require(
            UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")
        ))
        let cell = gridCell ?? NormalizedGridCell(row: 0, column: 0)
        let pointer = PointerTotals(
            clicks: cell.clicks,
            scroll: ScrollTotals(up: scrollUp, down: scrollDown),
            estimatedDistanceMilliPoints: 1_000
        )
        return try InputAggregate(
            id: id,
            period: period ?? hourlyPeriod(start: "2026-08-01T00:00:00Z"),
            physicalKeyCounts: keyCount == 0 ? [] : [
                PhysicalKeyCount(hardwareKeyCode: 42, count: keyCount)
            ],
            committedCharacterCount: committedCharacterCount,
            applicationTotals: [
                ApplicationInputTotals(
                    applicationIdentifier: ApplicationIdentifier(
                        rawValue: try #require(UUID(
                            uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
                        ))
                    ),
                    keyCount: appKeyCount,
                    pointer: pointer
                )
            ],
            displays: [
                DisplayInputAggregate(
                    display: DisplayContext(id: displayID, topologyRevision: displayRevision),
                    pointer: pointer,
                    grid: try NormalizedDisplayGrid(rows: 8, columns: 12, cells: [cell])
                )
            ],
            includedDurationMilliseconds: includedMilliseconds,
            collectorVersions: collectorVersions,
            layoutVersions: layoutVersions
        )
    }

    private func hourlyPeriod(start value: String) throws -> InputAggregatePeriod {
        let start = instant(value)
        return try InputAggregatePeriod(
            start: start,
            end: start.addingTimeInterval(3_600),
            granularity: .hour,
            timeZoneIdentifier: "UTC"
        )
    }

    private func corruptedEncoding(
        of aggregate: InputAggregate,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(aggregate)
        var root = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try mutate(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func mutateDictionary(
        _ root: inout [String: Any],
        key: String,
        mutate: (inout [String: Any]) throws -> Void
    ) throws {
        var nested = try #require(root[key] as? [String: Any])
        try mutate(&nested)
        root[key] = nested
    }

    private func instant(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)!
    }
}
