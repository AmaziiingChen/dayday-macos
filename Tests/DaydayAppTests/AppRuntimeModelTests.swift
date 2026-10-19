@testable import DaydayApp
import DaydayCapture
import DaydayCore
import Foundation
import Testing

@Suite("App runtime model", .serialized)
@MainActor
struct AppRuntimeModelTests {
    @Test("Permission snapshots never imply collection has started")
    func collectionStatusUsesOnlyTruthfulStates() {
        let provider = PreviewAppRuntimeSnapshotProvider(value: .unknown)

        let unknown = AppRuntimeModel(provider: provider)
        #expect(unknown.collectionStatus == .checking)

        let notAuthorized = AppRuntimeModel(
            provider: provider,
            initialSnapshot: .previewPermissionRequired
        )
        #expect(notAuthorized.collectionStatus == .permissionRequired)

        let authorized = AppRuntimeModel(
            provider: provider,
            initialSnapshot: .previewAuthorized
        )
        #expect(authorized.collectionStatus == .notConfigured)
    }

    @Test("H1 bootstrap status takes precedence over permission preview state")
    func h1StatusIsPresentedTruthfully() {
        let model = AppRuntimeModel(
            provider: PreviewAppRuntimeSnapshotProvider(value: .previewAuthorized)
        )

        model.applyH1Snapshot(H1CollectionRuntimeSnapshot(status: .running, historyRevision: 4))
        #expect(model.collectionStatus == .running)

        model.reportProductionBootstrapFailure()
        #expect(model.collectionStatus == .failed)
    }

    @Test("Authorized live facts never render a stale H1 permission warning")
    func authorizedFactsOverrideStaleAuthorizationWaitPresentation() {
        let authorized = AppRuntimeModel(
            provider: PreviewAppRuntimeSnapshotProvider(value: .previewAuthorized),
            initialSnapshot: .previewAuthorized
        )
        authorized.applyH1Snapshot(
            H1CollectionRuntimeSnapshot(status: .waitingForAuthorization, historyRevision: 0)
        )
        #expect(authorized.collectionStatus == .starting)

        let unauthorized = AppRuntimeModel(
            provider: PreviewAppRuntimeSnapshotProvider(value: .previewPermissionRequired),
            initialSnapshot: .previewPermissionRequired
        )
        unauthorized.applyH1Snapshot(
            H1CollectionRuntimeSnapshot(status: .waitingForAuthorization, historyRevision: 0)
        )
        #expect(unauthorized.collectionStatus == .permissionRequired)
    }

    @Test("Manual refresh also reconciles the production collection gates")
    func manualRefreshReconcilesCollectionGates() async {
        let provider = SnapshotProvider(result: .previewAuthorized)
        let gateRefresh = GateRefreshProbe()
        let model = AppRuntimeModel(provider: provider)
        model.setCollectionGateRefresher {
            await gateRefresh.refresh()
        }

        model.requestRefresh()

        #expect(await eventually { @MainActor in !model.isRefreshing })
        #expect(await gateRefresh.callCount == 1)
        #expect(model.snapshot.screenRecording == .authorized)
        #expect(model.snapshot.accessibility == .authorized)
        #expect(model.snapshot.displays == AppRuntimeSnapshot.previewAuthorized.displays)
    }

    @Test("Logical size and rotation remain visible when pixel size is unavailable")
    func displayDescriptionFallsBackWithoutLosingRotation() {
        let display = AppRuntimeDisplay(
            id: 7,
            logicalWidth: 1_080,
            logicalHeight: 1_920,
            pixelWidth: nil,
            pixelHeight: nil,
            rotationDegrees: 90,
            isMain: false,
            isBuiltIn: false,
            isMirrored: false
        )

        #expect(display.dimensionsDescription == "1080 × 1920 点 · 旋转 90°")
    }

    @Test("Starting monitoring twice creates one refresh loop and stop cancels its sleep")
    func startIsIdempotentAndStopCancelsSleep() async {
        let provider = SnapshotProvider(result: .previewAuthorized)
        let sleeper = SleepProbe()
        let interval = Duration.seconds(17)
        let model = AppRuntimeModel(
            provider: provider,
            schedule: AppRuntimeSchedule(
                now: { Date(timeIntervalSinceReferenceDate: 42) },
                sleep: { duration in try await sleeper.sleep(for: duration) }
            ),
            refreshInterval: interval
        )

        model.startMonitoring()
        model.startMonitoring()

        let started = await eventually {
            let providerMetrics = await provider.metrics()
            let sleepMetrics = await sleeper.metrics()
            return providerMetrics.callCount == 1 && sleepMetrics.started == [interval]
        }
        #expect(started)

        model.stopMonitoring()

        let cancelled = await eventually {
            await sleeper.metrics().cancellationCount == 1
        }
        #expect(cancelled)
        let providerMetrics = await provider.metrics()
        #expect(providerMetrics.maximumConcurrentCalls == 1)
    }

    @Test("Repeated manual refreshes merge and never call the provider concurrently")
    func manualRefreshesMergeWithoutConcurrency() async {
        let fixedDate = Date(timeIntervalSinceReferenceDate: 12_345)
        let provider = SnapshotProvider(result: .previewAuthorized, blocksUntilCancelled: true)
        let model = AppRuntimeModel(
            provider: provider,
            schedule: AppRuntimeSchedule(
                now: { fixedDate },
                sleep: { _ in }
            )
        )

        model.requestRefresh()
        model.requestRefresh()
        model.requestRefresh()

        let inFlight = await eventually {
            let metrics = await provider.metrics()
            return metrics.callCount == 1 && metrics.activeCalls == 1
        }
        #expect(inFlight)
        #expect(model.isRefreshing)

        let metrics = await provider.metrics()
        #expect(metrics.callCount == 1)
        #expect(metrics.maximumConcurrentCalls == 1)
        #expect(metrics.requestedDates == [fixedDate])

        model.stopMonitoring()

        let stopped = await eventually {
            let metrics = await provider.metrics()
            return metrics.cancellationCount == 1 && metrics.activeCalls == 0
        }
        #expect(stopped)
        #expect(!model.isRefreshing)
        #expect(model.snapshot == .unknown)
    }

    @Test("Leaving Today cancels an in-flight timeline page without changing collection")
    func leavingTodayCancelsTimelinePage() async {
        let repository = SuspendingPagedObjectiveRepository()
        let model = AppRuntimeModel(
            provider: PreviewAppRuntimeSnapshotProvider(value: .previewAuthorized),
            schedule: AppRuntimeSchedule(
                now: { Date(timeIntervalSince1970: 1_800_100_000) },
                sleep: { _ in }
            )
        )

        model.configureToday(repository: repository)
        #expect(await eventually { await repository.metrics().startedPages == 1 })
        #expect(model.isRefreshingTodayTimeline)
        let collectionStatusBeforeNavigation = model.collectionStatus

        model.setTodayTimelineVisible(false)
        #expect(await eventually { await repository.metrics().cancelledPages == 1 })
        #expect(!model.isRefreshingTodayTimeline)
        #expect(model.collectionStatus == collectionStatusBeforeNavigation)
    }
}

private actor SnapshotProvider: AppRuntimeSnapshotProviding {
    struct Metrics: Sendable {
        let callCount: Int
        let activeCalls: Int
        let maximumConcurrentCalls: Int
        let cancellationCount: Int
        let requestedDates: [Date]
    }

    private let result: AppRuntimeSnapshot
    private let blocksUntilCancelled: Bool
    private var callCount = 0
    private var activeCalls = 0
    private var maximumConcurrentCalls = 0
    private var cancellationCount = 0
    private var requestedDates: [Date] = []

    init(result: AppRuntimeSnapshot, blocksUntilCancelled: Bool = false) {
        self.result = result
        self.blocksUntilCancelled = blocksUntilCancelled
    }

    func snapshot(at date: Date) async -> AppRuntimeSnapshot {
        callCount += 1
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        requestedDates.append(date)
        defer { activeCalls -= 1 }

        if blocksUntilCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancellationCount += 1
            }
        }

        return AppRuntimeSnapshot(
            screenRecording: result.screenRecording,
            accessibility: result.accessibility,
            displayInventoryState: result.displayInventoryState,
            displays: result.displays,
            checkedAt: date
        )
    }

    func metrics() -> Metrics {
        Metrics(
            callCount: callCount,
            activeCalls: activeCalls,
            maximumConcurrentCalls: maximumConcurrentCalls,
            cancellationCount: cancellationCount,
            requestedDates: requestedDates
        )
    }
}

private actor GateRefreshProbe {
    private(set) var callCount = 0

    func refresh() {
        callCount += 1
    }
}

private actor SleepProbe {
    struct Metrics: Sendable {
        let started: [Duration]
        let cancellationCount: Int
    }

    private var started: [Duration] = []
    private var cancellationCount = 0

    func sleep(for duration: Duration) async throws {
        started.append(duration)
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancellationCount += 1
            throw error
        }
    }

    func metrics() -> Metrics {
        Metrics(started: started, cancellationCount: cancellationCount)
    }
}

private actor SuspendingPagedObjectiveRepository: ObjectiveEventPageRepository {
    struct Metrics: Sendable {
        let startedPages: Int
        let cancelledPages: Int
    }

    private var startedPages = 0
    private var cancelledPages = 0

    func insert(_ event: ObjectiveEvent) async throws -> ObjectiveEventInsertResult { .inserted }

    func fetch(occurredIn range: Range<Date>) async throws -> [ObjectiveEvent] { [] }

    func fetchPage(
        occurredIn range: Range<Date>,
        before cursor: ObjectiveEventPageCursor?,
        limit: Int
    ) async throws -> ObjectiveEventPage {
        startedPages += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelledPages += 1
            throw error
        }
        return .init(events: [], nextCursor: nil)
    }

    func metrics() -> Metrics {
        .init(startedPages: startedPages, cancelledPages: cancelledPages)
    }
}

private func eventually(
    attempts: Int = 500,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
