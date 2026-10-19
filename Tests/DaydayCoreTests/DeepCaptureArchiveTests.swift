import DaydayCore
import Foundation
import Testing

@Suite("Owner Deep Capture archive contracts")
struct DeepCaptureArchiveTests {
  @Test("visible text is bounded and objective text cannot claim inference provenance")
  func visibleTextContract() throws {
    let record = try VisibleContentObservation(provenance: provenance(), kind: .objectiveText, classification: .document, redactionState: .redacted, text: "Visible, redacted text")
    #expect(record.text == "Visible, redacted text")
    #expect(throws: VisibleContentObservation.ValidationError.objectiveCannotHaveInferenceOrigin) {
      try VisibleContentObservation(provenance: provenance(), kind: .objectiveText, redactionState: .redacted, text: "text", inferenceOrigin: "local.rule.v1")
    }
  }

  @Test("hard exclusion is representable but cannot retain text or metrics")
  func exclusionsAreContentFree() throws {
    let excluded = try VisibleContentObservation(provenance: provenance(windowLabel: nil), kind: .objectiveText, redactionState: .excluded, suppressionReason: .secureInput)
    #expect(excluded.text == nil)
    #expect(throws: VisibleContentObservation.ValidationError.exclusionMustNotContainContent) {
      try VisibleContentObservation(provenance: provenance(windowLabel: nil), kind: .objectiveText, redactionState: .excluded, suppressionReason: .secureInput, text: "secret")
    }
    #expect(throws: VisibleContentObservation.ValidationError.exclusionMustUseSafeProvenance) {
      try VisibleContentObservation(provenance: provenance(windowLabel: "Password reset"), kind: .objectiveText, redactionState: .excluded, suppressionReason: .secureInput)
    }
    #expect(throws: TextProductionAggregate.ValidationError.excludedMustBeZero) {
      try TextProductionAggregate(provenance: provenance(windowLabel: nil), insertedGraphemeCount: 1, suppressionReason: .secureInput)
    }
    #expect(throws: TextProductionAggregate.ValidationError.excludedMustUseSafeProvenance) {
      try TextProductionAggregate(provenance: provenance(windowLabel: "Private message"), suppressionReason: .incognito)
    }
  }

  @Test("text production contains only totals and coarse non-overlapping intervals")
  func textProductionContract() throws {
    let start = date("2026-08-03T01:00:00Z")
    let interval = try TextProductionInterval(start: start, end: start.addingTimeInterval(60))
    let aggregate = try TextProductionAggregate(provenance: try provenance(start: start, end: start.addingTimeInterval(300)), insertedGraphemeCount: 3, insertedUnicodeScalarCount: 4, estimatedWordCount: 1, intervals: [interval])
    #expect(aggregate.insertedGraphemeCount == 3)
    #expect(aggregate.intervals == [interval])
  }

  private func provenance(start: Date? = nil, end: Date? = nil, windowLabel: String? = "Document") throws -> VisibleContentProvenance {
    try VisibleContentProvenance(source: CollectorSource(collector: .screenUnderstanding, collectorVersion: "1.0.0", payloadSchemaVersion: 1), observedAt: start ?? date("2026-08-03T01:00:00Z"), endedAt: end, timeZoneIdentifier: "UTC", applicationIdentifier: ApplicationIdentifier(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), windowLabel: windowLabel, display: DisplayContext(id: DisplayID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!), topologyRevision: 1))
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
