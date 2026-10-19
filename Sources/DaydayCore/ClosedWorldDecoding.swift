import Foundation

/// Rejects undeclared keyed fields in closed durable Core values.
enum ClosedWorldDecoding {
  private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      intValue = nil
    }

    init?(intValue: Int) {
      stringValue = String(intValue)
      self.intValue = intValue
    }
  }

  static func container<Key: CodingKey>(
    keyedBy type: Key.Type,
    typeName: String,
    from decoder: Decoder
  ) throws -> KeyedDecodingContainer<Key> {
    let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
    guard dynamicContainer.allKeys.allSatisfy({ Key(stringValue: $0.stringValue) != nil }) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "\(typeName) contains an unknown key"
        ))
    }
    return try decoder.container(keyedBy: Key.self)
  }

  static func nestedContainer<ParentKey: CodingKey, Key: CodingKey>(
    from parent: KeyedDecodingContainer<ParentKey>,
    forKey key: ParentKey,
    keyedBy type: Key.Type,
    typeName: String
  ) throws -> KeyedDecodingContainer<Key> {
    let dynamicContainer = try parent.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key)
    guard dynamicContainer.allKeys.allSatisfy({ Key(stringValue: $0.stringValue) != nil }) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: dynamicContainer.codingPath,
          debugDescription: "\(typeName) contains an unknown key"
        ))
    }
    return try parent.nestedContainer(keyedBy: Key.self, forKey: key)
  }
}
