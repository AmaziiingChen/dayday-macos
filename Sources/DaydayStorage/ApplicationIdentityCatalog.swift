import CryptoKit
import DaydayCore
import Foundation
import Security

enum ApplicationIdentityCatalog {
  static let saltVersion: Int64 = 1

  static func normalizedBundleIdentifier(_ value: String) throws -> Data {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 255,
      bytes.allSatisfy({ $0.isASCIIAlphaNumeric || $0 == 46 || $0 == 45 })
    else { throw ObjectiveEventStoreError.invalidApplicationIdentity }
    return Data(bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
  }

  struct DerivedIdentity: Equatable {
    let identifier: ApplicationIdentifier
    let collisionGuard: Data
  }

  static func derive(normalized: Data, salt: Data) throws -> DerivedIdentity {
    guard salt.count == 32 else {
      throw ObjectiveEventStoreError.corruptedSchema("application identity metadata")
    }
    var input = Data("dayday.application-id.v1".utf8)
    input.append(salt)
    input.append(normalized)
    let digest = Array(SHA256.hash(data: input))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let text = bytes.map { String(format: "%02x", $0) }.joined()
    guard
      let uuid = UUID(
        uuidString:
          "\(text.prefix(8))-\(text.dropFirst(8).prefix(4))-\(text.dropFirst(12).prefix(4))-\(text.dropFirst(16).prefix(4))-\(text.dropFirst(20))"
      )
    else {
      throw ObjectiveEventStoreError.corruptedSchema("application identity derivation")
    }
    return DerivedIdentity(
      identifier: ApplicationIdentifier(rawValue: uuid), collisionGuard: Data(digest.suffix(16)))
  }

  static func newSalt() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw ObjectiveEventStoreError.corruptedSchema("application identity salt")
    }
    return Data(bytes)
  }
}

extension UInt8 {
  fileprivate var isASCIIAlphaNumeric: Bool {
    (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
  }
}
