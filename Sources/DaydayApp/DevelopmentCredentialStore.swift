import DaydayAI
import DaydayIntegrations
import Foundation

#if DEBUG
  /// Debug builds deliberately keep provider keys in the local app preferences so repeated
  /// ad-hoc signing during development does not cause macOS Keychain prompts. This type and its
  /// values are excluded from Release builds and source control.
  final class DevelopmentCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    private static let keyPrefix = "dayday.development.plaintext-provider-credential."
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
      self.defaults = defaults
    }

    func credential(for account: String) throws -> String? {
      defaults.string(forKey: Self.key(for: account))
    }

    func save(_ credential: String, for account: String) throws {
      guard !credential.isEmpty else { throw ProviderCredentialError.invalidCredential }
      defaults.set(credential, forKey: Self.key(for: account))
    }

    func removeCredential(for account: String) throws {
      defaults.removeObject(forKey: Self.key(for: account))
    }

    private static func key(for account: String) -> String {
      keyPrefix + account
    }
  }
#endif

enum AppCredentialStoreFactory {
  static func make(defaults: UserDefaults) -> any ProviderCredentialStoring {
    #if DEBUG
      DevelopmentCredentialStore(defaults: defaults)
    #else
      KeychainProviderCredentialStore()
    #endif
  }

  static var storageDescription: String {
    #if DEBUG
      "本机开发配置（明文）"
    #else
      "钥匙串"
    #endif
  }
}

protocol AppHealthPairingCredentialStoring: Sendable {
  func load() throws -> HealthPairingCredential?
  func save(_ credential: HealthPairingCredential) throws
  func remove() throws
}

extension HealthPairingCredentialStore: AppHealthPairingCredentialStoring {}

#if DEBUG
  /// The local development app is rebuilt and signed frequently. Keeping its pairing credential
  /// in a dedicated development preference avoids repeated macOS Keychain authorization prompts
  /// caused by a changing teamless code identity. Release builds continue to use the Keychain.
  final class DevelopmentHealthPairingCredentialStore:
    AppHealthPairingCredentialStoring, @unchecked Sendable
  {
    static let storageKey = "dayday.development.health-local-pairing"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
      self.defaults = defaults
    }

    func load() throws -> HealthPairingCredential? {
      guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
      return try JSONDecoder().decode(HealthPairingCredential.self, from: data)
    }

    func save(_ credential: HealthPairingCredential) throws {
      defaults.set(try JSONEncoder().encode(credential), forKey: Self.storageKey)
    }

    func remove() throws {
      defaults.removeObject(forKey: Self.storageKey)
    }
  }
#endif

enum AppHealthPairingCredentialStoreFactory {
  static func make(defaults: UserDefaults = .standard) -> any AppHealthPairingCredentialStoring {
    #if DEBUG
      DevelopmentHealthPairingCredentialStore(defaults: defaults)
    #else
      HealthPairingCredentialStore()
    #endif
  }
}
