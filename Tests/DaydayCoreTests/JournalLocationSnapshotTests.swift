import DaydayCore
import Foundation
import Testing

@Suite("Journal location snapshot")
struct JournalLocationSnapshotTests {
  @Test("valid captures retain coordinates and the reported accuracy")
  func validCapture() throws {
    let snapshot = try JournalLocationSnapshot(
      journalEntryID: JournalEntryID(),
      dayID: DayID(),
      latitude: 22.543096,
      longitude: 114.057865,
      altitude: 34.2,
      horizontalAccuracy: 4.5,
      verticalAccuracy: 8.0,
      capturedAt: Date(timeIntervalSinceReferenceDate: 800)
    )

    #expect(snapshot.latitude == 22.543096)
    #expect(snapshot.longitude == 114.057865)
    #expect(snapshot.horizontalAccuracy == 4.5)
  }

  @Test("non-finite coordinates and negative accuracy are rejected")
  func rejectsInvalidPrecision() {
    #expect(throws: JournalLocationSnapshot.ValidationError.invalidLatitude) {
      _ = try JournalLocationSnapshot(
        journalEntryID: JournalEntryID(), dayID: DayID(), latitude: .infinity,
        longitude: 114, altitude: nil, horizontalAccuracy: 1,
        verticalAccuracy: nil, capturedAt: .now)
    }
    #expect(throws: JournalLocationSnapshot.ValidationError.invalidHorizontalAccuracy) {
      _ = try JournalLocationSnapshot(
        journalEntryID: JournalEntryID(), dayID: DayID(), latitude: 22,
        longitude: 114, altitude: nil, horizontalAccuracy: -1,
        verticalAccuracy: nil, capturedAt: .now)
    }
  }

  @Test("readable place labels are normalized and bounded")
  func validatesReadablePlaceName() throws {
    let snapshot = try JournalLocationSnapshot(
      journalEntryID: JournalEntryID(), dayID: DayID(), latitude: 23.136268,
      longitude: 113.367124, altitude: nil, horizontalAccuracy: 35,
      verticalAccuracy: nil, capturedAt: .now,
      placeName: "  广东省广州市天河区枫叶路  "
    )

    #expect(snapshot.placeName == "广东省广州市天河区枫叶路")
    #expect(throws: JournalLocationSnapshot.ValidationError.invalidPlaceName) {
      _ = try JournalLocationSnapshot(
        journalEntryID: JournalEntryID(), dayID: DayID(), latitude: 23,
        longitude: 113, altitude: nil, horizontalAccuracy: 8,
        verticalAccuracy: nil, capturedAt: .now,
        placeName: String(repeating: "地", count: 257)
      )
    }
  }
}
