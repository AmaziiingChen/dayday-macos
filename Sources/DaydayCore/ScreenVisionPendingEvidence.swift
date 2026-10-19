import Foundation

/// Opaque identity for one compressed evidence derivative waiting for visual understanding.
public struct ScreenVisionPendingEvidenceID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { self.init(rawValue: UUID()) }
}

/// A bounded, compressed screen derivative retained only until a visual segment has been produced.
/// It never accepts an original capture and contains neither input events nor raw OCR output.
public struct ScreenVisionPendingEvidence: Codable, Equatable, Hashable, Sendable {
  public static let currentRecordVersion = 1
  public static let maximumJPEGBytes = 2_000_000
  public static let maximumDimension = 1_600

  public enum ValidationError: Error, Equatable, Sendable {
    case unsupportedRecordVersion(Int)
    case invalidTimestamp
    case emptyJPEG
    case oversizedJPEG(Int)
    case invalidDimensions
    case oversizedDimension(Int)
    case tooManyOCRLines(Int)
  }

  public let id: ScreenVisionPendingEvidenceID
  public let observedAt: Date
  public let display: DisplayContext
  public let encodedJPEG: Data
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let redactedOCRLines: [RedactedOCRLine]
  public let recordVersion: Int

  public init(
    id: ScreenVisionPendingEvidenceID = .init(),
    observedAt: Date,
    display: DisplayContext,
    encodedJPEG: Data,
    pixelWidth: Int,
    pixelHeight: Int,
    redactedOCRLines: [RedactedOCRLine],
    recordVersion: Int = currentRecordVersion
  ) throws {
    guard recordVersion == Self.currentRecordVersion else {
      throw ValidationError.unsupportedRecordVersion(recordVersion)
    }
    guard observedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw ValidationError.invalidTimestamp
    }
    guard !encodedJPEG.isEmpty else { throw ValidationError.emptyJPEG }
    guard encodedJPEG.count <= Self.maximumJPEGBytes else {
      throw ValidationError.oversizedJPEG(encodedJPEG.count)
    }
    guard pixelWidth > 0, pixelHeight > 0 else { throw ValidationError.invalidDimensions }
    guard max(pixelWidth, pixelHeight) <= Self.maximumDimension else {
      throw ValidationError.oversizedDimension(max(pixelWidth, pixelHeight))
    }
    guard redactedOCRLines.count <= OCRArtifact.maximumLineCount else {
      throw ValidationError.tooManyOCRLines(redactedOCRLines.count)
    }
    self.id = id
    self.observedAt = observedAt
    self.display = display
    self.encodedJPEG = encodedJPEG
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.redactedOCRLines = redactedOCRLines
    self.recordVersion = recordVersion
  }
}

/// Crash-safe queue for compressed visual evidence. Queue consumers remove evidence only after
/// its structured visual segment is durably archived; failed calls leave it eligible for retry.
public protocol ScreenVisionPendingEvidenceRepository: Sendable {
  func insert(_ evidence: ScreenVisionPendingEvidence) async throws -> DeepCaptureInsertResult
  func pendingScreenVisionEvidence(limit: Int) async throws -> [ScreenVisionPendingEvidence]
  func removePendingScreenVisionEvidence(ids: [ScreenVisionPendingEvidenceID]) async throws
}
