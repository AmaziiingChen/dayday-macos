import DaydayCore
import Foundation

/// The single front-end projection for privacy-closed input aggregates.
/// Every surface uses these definitions: a key press is a non-repeat observed
/// key-down event, a click is a mouse-down event, and a scroll action is one
/// non-zero system scroll event (not its directional magnitude).
struct InputMetricSummary: Equatable, Sendable {
    private(set) var keyPressCount: UInt64
    private(set) var clickCount: UInt64
    private(set) var scrollActionCount: UInt64
    private(set) var scrollMagnitude: UInt64
    private(set) var hasLegacyScrollMagnitude: Bool

    static let empty = InputMetricSummary(
        keyPressCount: 0,
        clickCount: 0,
        scrollActionCount: 0,
        scrollMagnitude: 0,
        hasLegacyScrollMagnitude: false
    )

    static func make(from aggregates: [InputAggregate]) -> InputMetricSummary {
        aggregates.reduce(into: .empty) { result, aggregate in
            let keys = aggregate.physicalKeyCounts.isEmpty
                ? aggregate.applicationTotals.map(\.keyCount)
                : aggregate.physicalKeyCounts.map(\.count)
            result.keyPressCount = sum(result.keyPressCount, keys)

            let pointers = aggregate.displays.isEmpty
                ? aggregate.applicationTotals.map(\.pointer)
                : aggregate.displays.map(\.pointer)
            for pointer in pointers {
                result.clickCount = sum(
                    result.clickCount,
                    [pointer.clicks.left, pointer.clicks.right, pointer.clicks.other]
                )
                result.scrollActionCount = sum(
                    result.scrollActionCount,
                    [pointer.scrollEventCount]
                )
                let magnitude = sum(
                    0,
                    [
                        pointer.scroll.up,
                        pointer.scroll.down,
                        pointer.scroll.left,
                        pointer.scroll.right,
                    ]
                )
                result.scrollMagnitude = sum(result.scrollMagnitude, [magnitude])
                if pointer.scrollEventCount == 0, magnitude > 0,
                   !aggregate.collectorVersions.contains("h1-input-v2"),
                   !aggregate.collectorVersions.contains("h1-input-v3") {
                    result.hasLegacyScrollMagnitude = true
                }
            }
        }
    }

    private static func sum(_ initial: UInt64, _ values: [UInt64]) -> UInt64 {
        values.reduce(initial) { partial, value in
            let result = partial.addingReportingOverflow(value)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }
}

/// A combined, read-only detail for durable foreground facts and durable
/// input aggregates. It never exposes key content, ordering, pointer paths,
/// or a focus/productivity judgment.
struct ApplicationInputDetailPresentation: Equatable {
    enum State: Equatable {
        case empty
        case populated
        case partial
        case failure
    }

    struct InputTotals: Equatable {
        let keyCount: UInt64
        let clickCount: UInt64
        let scrollCount: UInt64

        init(
            keyCount: UInt64,
            clickCount: UInt64,
            scrollCount: UInt64
        ) {
            self.keyCount = keyCount
            self.clickCount = clickCount
            self.scrollCount = scrollCount
        }
    }

    struct Application: Identifiable, Equatable {
        let applicationIdentifier: ApplicationIdentifier
        let displayLabel: String?
        let foregroundDuration: TimeInterval
        let foregroundIntervalCount: Int
        let input: InputTotals

        var id: UUID { applicationIdentifier.rawValue }
    }

    let state: State
    let foregroundDuration: TimeInterval
    let noForegroundFactDuration: TimeInterval
    let applicationSwitchCount: Int
    let input: InputTotals
    let applications: [Application]
}

enum ApplicationInputDetailPresentationAdapter {
    enum AggregationError: Error, Equatable {
        case unsignedOverflow
    }

    private struct MutableInput {
        var keyCount: UInt64 = 0
        var clickCount: UInt64 = 0
        var scrollCount: UInt64 = 0
    }

    static func make(
        applicationUsage: ApplicationUsagePresentation,
        inputAggregates: [InputAggregate]
    ) throws -> ApplicationInputDetailPresentation {
        guard applicationUsage.state != .failure else {
            return .init(
                state: .failure,
                foregroundDuration: 0,
                noForegroundFactDuration: 0,
                applicationSwitchCount: 0,
                input: .init(keyCount: 0, clickCount: 0, scrollCount: 0),
                applications: []
            )
        }

        let aggregateInput = InputMetricSummary.make(from: inputAggregates)
        var perApplication: [ApplicationIdentifier: MutableInput] = [:]
        for aggregate in inputAggregates {
            // Global input facts are stored independently of an application.
            // The event tap intentionally does not attach a foreground app to
            // a key or pointer event, so deriving the page total only from
            // `applicationTotals` makes real global activity appear as zero.
            for input in aggregate.applicationTotals {
                let totals = try add(input.pointer, keys: input.keyCount, to: perApplication[input.applicationIdentifier] ?? MutableInput())
                perApplication[input.applicationIdentifier] = totals
            }
        }

        let summaries = Dictionary(uniqueKeysWithValues: applicationUsage.summaries.map {
            ($0.applicationIdentifier, $0)
        })
        let identifiers = Set(summaries.keys).union(perApplication.keys)
        let applications = identifiers.map { identifier in
            let summary = summaries[identifier]
            let input = perApplication[identifier] ?? MutableInput()
            return ApplicationInputDetailPresentation.Application(
                applicationIdentifier: identifier,
                displayLabel: summary?.displayLabel,
                foregroundDuration: summary?.duration ?? 0,
                foregroundIntervalCount: summary?.intervalCount ?? 0,
                input: .init(
                    keyCount: input.keyCount,
                    clickCount: input.clickCount,
                    scrollCount: input.scrollCount
                )
            )
        }
        .sorted(by: stableOrder)

        let hasFacts = applicationUsage.trackedDuration > 0 || aggregateInput.keyPressCount > 0
            || aggregateInput.clickCount > 0 || aggregateInput.scrollActionCount > 0
        let state: ApplicationInputDetailPresentation.State
        if !hasFacts {
            state = .empty
        } else if applicationUsage.hasIncompleteForegroundFacts {
            state = .partial
        } else {
            state = .populated
        }

        return .init(
            state: state,
            foregroundDuration: applicationUsage.trackedDuration,
            noForegroundFactDuration: applicationUsage.noForegroundFactDuration,
            applicationSwitchCount: applicationUsage.applicationSwitchCount,
            input: .init(
                keyCount: aggregateInput.keyPressCount,
                clickCount: aggregateInput.clickCount,
                scrollCount: aggregateInput.scrollActionCount
            ),
            applications: applications
        )
    }

    private static func stableOrder(
        _ lhs: ApplicationInputDetailPresentation.Application,
        _ rhs: ApplicationInputDetailPresentation.Application
    ) -> Bool {
        if lhs.foregroundDuration != rhs.foregroundDuration {
            return lhs.foregroundDuration > rhs.foregroundDuration
        }
        if lhs.input.keyCount != rhs.input.keyCount { return lhs.input.keyCount > rhs.input.keyCount }
        return lhs.applicationIdentifier.rawValue.uuidString < rhs.applicationIdentifier.rawValue.uuidString
    }

    private static func add(
        _ pointer: PointerTotals,
        keys: UInt64,
        to current: MutableInput
    ) throws -> MutableInput {
        .init(
            keyCount: try checkedAdd(current.keyCount, keys),
            clickCount: try checkedAdd(current.clickCount, try clickCount(pointer.clicks)),
            scrollCount: try checkedAdd(current.scrollCount, pointer.scrollEventCount)
        )
    }

    private static func add(_ incoming: MutableInput, to current: MutableInput) throws -> MutableInput {
        .init(
            keyCount: try checkedAdd(current.keyCount, incoming.keyCount),
            clickCount: try checkedAdd(current.clickCount, incoming.clickCount),
            scrollCount: try checkedAdd(current.scrollCount, incoming.scrollCount)
        )
    }

    private static func clickCount(_ clicks: ClickCounts) throws -> UInt64 {
        try checkedAdd(try checkedAdd(clicks.left, clicks.right), clicks.other)
    }

    static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw AggregationError.unsignedOverflow }
        return result.partialValue
    }
}
