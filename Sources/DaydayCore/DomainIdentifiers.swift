import Foundation

/// An opaque identifier for one persisted objective event.
public struct EventID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public init() {
    self.init(rawValue: UUID())
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "EventID",
      from: decoder
    )
    self.init(rawValue: try container.decode(UUID.self, forKey: .rawValue))
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}

/// An opaque identity assigned to a display by the capture layer.
///
/// This is deliberately not a `CGDirectDisplayID`: that platform value is an
/// implementation detail and may be recycled as display topology changes.
public struct DisplayID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public init() {
    self.init(rawValue: UUID())
  }

  public init(from decoder: Decoder) throws {
    let container = try ClosedWorldDecoding.container(
      keyedBy: CodingKeys.self,
      typeName: "DisplayID",
      from: decoder
    )
    self.init(rawValue: try container.decode(UUID.self, forKey: .rawValue))
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }
}
