import Foundation

/// User-authored writing guidance for work reports. It is stored locally, injected into the
/// generation prompt, and never becomes part of the `WorkReportContext` allowlist projection.
public struct WorkReportWritingPreferences: Codable, Equatable, Hashable, Sendable {
  public var tone: String
  public var alwaysInclude: String
  public var alwaysAvoid: String
  /// Owner-editable task instructions. An empty value uses the app's reviewed default.
  public var taskInstructions: String
  /// Owner-editable output contract. An empty value uses the app's reviewed Markdown default.
  public var outputInstructions: String

  public init(
    tone: String = "",
    alwaysInclude: String = "",
    alwaysAvoid: String = "",
    taskInstructions: String = "",
    outputInstructions: String = ""
  ) {
    self.tone = tone
    self.alwaysInclude = alwaysInclude
    self.alwaysAvoid = alwaysAvoid
    self.taskInstructions = taskInstructions
    self.outputInstructions = outputInstructions
  }

  public static let standard = WorkReportWritingPreferences()

  public var isEmpty: Bool {
    tone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && alwaysInclude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && alwaysAvoid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && taskInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && outputInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    tone = try values.decodeIfPresent(String.self, forKey: .tone) ?? ""
    alwaysInclude = try values.decodeIfPresent(String.self, forKey: .alwaysInclude) ?? ""
    alwaysAvoid = try values.decodeIfPresent(String.self, forKey: .alwaysAvoid) ?? ""
    taskInstructions = try values.decodeIfPresent(String.self, forKey: .taskInstructions) ?? ""
    outputInstructions = try values.decodeIfPresent(String.self, forKey: .outputInstructions) ?? ""
  }
}
