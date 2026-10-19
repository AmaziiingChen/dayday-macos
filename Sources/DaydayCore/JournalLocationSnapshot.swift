import Foundation

/// An explicitly requested, one-time position captured while writing a
/// journal. It is intentionally a personal artifact, not weather or work
/// context, and carries the accuracy reported by Core Location.
public struct JournalLocationSnapshot: Codable, Hashable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidLatitude
    case invalidLongitude
    case invalidAltitude
    case invalidHorizontalAccuracy
    case invalidVerticalAccuracy
    case invalidPlaceName
    case nonFiniteCaptureDate
  }

  public let id: JournalLocationSnapshotID
  public let journalEntryID: JournalEntryID
  public let dayID: DayID
  public let latitude: Double
  public let longitude: Double
  public let altitude: Double?
  public let horizontalAccuracy: Double
  public let verticalAccuracy: Double?
  public let capturedAt: Date
  public let placeName: String?

  public init(
    id: JournalLocationSnapshotID = JournalLocationSnapshotID(),
    journalEntryID: JournalEntryID,
    dayID: DayID,
    latitude: Double,
    longitude: Double,
    altitude: Double?,
    horizontalAccuracy: Double,
    verticalAccuracy: Double?,
    capturedAt: Date,
    placeName: String? = nil
  ) throws {
    guard latitude.isFinite, (-90...90).contains(latitude) else {
      throw ValidationError.invalidLatitude
    }
    guard longitude.isFinite, (-180...180).contains(longitude) else {
      throw ValidationError.invalidLongitude
    }
    if let altitude, !altitude.isFinite { throw ValidationError.invalidAltitude }
    guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else {
      throw ValidationError.invalidHorizontalAccuracy
    }
    if let verticalAccuracy, (!verticalAccuracy.isFinite || verticalAccuracy < 0) {
      throw ValidationError.invalidVerticalAccuracy
    }
    guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.nonFiniteCaptureDate
    }
    let normalizedPlaceName = placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalizedPlaceName, normalizedPlaceName.isEmpty || normalizedPlaceName.count > 256 {
      throw ValidationError.invalidPlaceName
    }

    self.id = id
    self.journalEntryID = journalEntryID
    self.dayID = dayID
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
    self.horizontalAccuracy = horizontalAccuracy
    self.verticalAccuracy = verticalAccuracy
    self.capturedAt = capturedAt
    self.placeName = normalizedPlaceName
  }
}

public enum JournalLocationSnapshotInsertResult: Equatable, Sendable {
  case inserted
  case alreadyPresent
}

public protocol JournalLocationSnapshotRepository: Sendable {
  func insert(_ snapshot: JournalLocationSnapshot) async throws -> JournalLocationSnapshotInsertResult
  func snapshots(for dayID: DayID) async throws -> [JournalLocationSnapshot]
  func schemaVersion() async throws -> Int
  func schemaFingerprint() async throws -> String
}
