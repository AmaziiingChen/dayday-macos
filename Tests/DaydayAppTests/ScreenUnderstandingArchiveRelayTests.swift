import DaydayCapture
import DaydayCore
import Foundation
import Testing

@testable import DaydayApp

struct ScreenUnderstandingArchiveRelayTests {
  @Test
  func archivesBoundedOCRAsObjectiveVisibleContent() async throws {
    let repository = VisibleContentFixtureRepository()
    let relay = ScreenUnderstandingArchiveRelay()
    await relay.attach(repository)
    let line = try RedactedOCRLine("A visible project note")
    let observation = try ObjectiveScreenTextObservation(
      frame: frameMetadata(),
      lines: [line],
      redactionApplied: false
    )

    await relay.receive(.recognizedText(observation))

    let records = await repository.records
    #expect(records.count == 1)
    #expect(records.first?.kind == .objectiveText)
    #expect(records.first?.classification == .ordinaryVisibleContent)
    #expect(records.first?.redactionState == .noRedactionNeeded)
    #expect(records.first?.text == line.value)
    #expect(records.first?.provenance.display == observation.frame.display)
    #expect(records.first?.provenance.source.collector == .screenUnderstanding)
  }

  @Test
  func fullyRedactedOCRArchivesOnlyAContentFreeExclusion() async throws {
    let repository = VisibleContentFixtureRepository()
    let relay = ScreenUnderstandingArchiveRelay()
    await relay.attach(repository)
    let observation = try ObjectiveScreenTextObservation(
      frame: frameMetadata(),
      lines: [],
      redactionApplied: true
    )

    await relay.receive(.recognizedText(observation))

    let record = try #require(await repository.records.first)
    #expect(record.redactionState == .excluded)
    #expect(record.suppressionReason == .mandatoryExclusion)
    #expect(record.text == nil)
    #expect(record.classification == nil)
  }

  private func frameMetadata() -> ObjectiveScreenFrameMetadata {
    ObjectiveScreenFrameMetadata(
      display: DisplayContext(id: DisplayID(), topologyRevision: 9),
      observedAt: Date(timeIntervalSinceReferenceDate: 4_000),
      pixelWidth: 1_920,
      pixelHeight: 1_080
    )
  }
}

private actor VisibleContentFixtureRepository: VisibleContentArchiveRepository {
  private(set) var records: [VisibleContentObservation] = []

  func insert(_ observation: VisibleContentObservation) async throws -> DeepCaptureInsertResult {
    records.append(observation)
    return .inserted
  }

  func fetchVisibleContent(observedIn range: Range<Date>) async throws
    -> [VisibleContentObservation]
  {
    records.filter { range.contains($0.provenance.observedAt) }
  }
}
