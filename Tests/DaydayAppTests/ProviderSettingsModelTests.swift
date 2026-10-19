import DaydayAI
import DaydayIntegrations
import Foundation
import Testing

@testable import DaydayApp

@MainActor
struct ProviderSettingsModelTests {
  @Test
  func developmentCredentialStoreKeepsCredentialsInItsLocalDefaultsSuite() throws {
    let defaults = makeDefaults()
    let store = DevelopmentCredentialStore(defaults: defaults)

    try store.save("development-only-key", for: "deepseek")

    #expect(try store.credential(for: "deepseek") == "development-only-key")
    try store.removeCredential(for: "deepseek")
    #expect(try store.credential(for: "deepseek") == nil)
  }

  @Test
  func developmentHealthPairingStoreAvoidsTheKeychainAndPersistsPairing() throws {
    let defaults = makeDefaults()
    let store = DevelopmentHealthPairingCredentialStore(defaults: defaults)
    let credential = try HealthPairingCredential(
      installationID: UUID(uuidString: "7603030A-5369-46EC-A0D4-B0C5D78D669A")!,
      secret: Data(repeating: 0x2A, count: 32)
    )

    try store.save(credential)

    #expect(try store.load() == credential)
    #expect(defaults.data(forKey: DevelopmentHealthPairingCredentialStore.storageKey) != nil)

    try store.remove()
    #expect(try store.load() == nil)
  }

  @Test
  func saveKeepsCredentialOutOfSerializedPreferences() throws {
    let defaults = makeDefaults()
    let credentials = FakeCredentialStore()
    let model = ProviderSettingsModel(credentialStore: credentials, defaults: defaults)
    model.apiKey = "test-only-key"

    model.save()

    #expect(credentials.values["deepseek"] == "test-only-key")
    #expect(model.apiKey.isEmpty)
    let preferences = try #require(defaults.data(forKey: ProviderSettingsModel.preferencesKey))
    #expect(!String(decoding: preferences, as: UTF8.self).contains("test-only-key"))
    #expect(model.hasStoredCredential)
  }

  @Test(arguments: ["not a URL", "https://api.deepseek.com"])
  func invalidEndpointOrModelDoesNotSaveCredential(_ endpoint: String) {
    let defaults = makeDefaults()
    let credentials = FakeCredentialStore()
    let model = ProviderSettingsModel(credentialStore: credentials, defaults: defaults)
    model.endpoint = endpoint
    if endpoint != "not a URL" { model.model = "   " }
    model.apiKey = "test-only-key"

    model.save()

    #expect(credentials.values.isEmpty)
    #expect(model.apiKey == "test-only-key")
    #expect(defaults.data(forKey: ProviderSettingsModel.preferencesKey) == nil)
  }

  @Test
  func developmentCredentialImportsOnceAndConnectionTestUsesNoPreferencesSecret() async {
    let defaults = makeDefaults()
    let credentials = FakeCredentialStore()
    let tester = FakeConnectionTester()
    let model = ProviderSettingsModel(
      credentialStore: credentials,
      defaults: defaults,
      developmentCredentialSource: StaticDevelopmentCredentialSource(values: [
        "DEEPSEEK_API_KEY": "development-only-key"
      ]),
      connectionTester: tester
    )

    #expect(model.hasStoredCredential)
    #expect(credentials.values["deepseek"] == "development-only-key")
    #expect(defaults.data(forKey: ProviderSettingsModel.preferencesKey) == nil)

    await model.testConnection()

    #expect(model.status == "连接成功，模型可用")
    #expect(await tester.callCount == 1)
    #expect(await tester.lastCredential == "development-only-key")
  }

  @Test
  func reportInstructionsPersistAndLegacyPreferencesReceiveReviewedDefaults() throws {
    let defaults = makeDefaults()
    let model = ProviderSettingsModel(
      credentialStore: FakeCredentialStore(),
      defaults: defaults
    )
    model.reportTaskInstructions = "按项目分组。"
    model.reportOutputInstructions = "输出 Markdown。"
    model.saveWritingPreferences()

    let restored = ProviderSettingsModel(
      credentialStore: FakeCredentialStore(),
      defaults: defaults
    )
    #expect(restored.reportTaskInstructions == "按项目分组。")
    #expect(restored.reportOutputInstructions == "输出 Markdown。")

    let legacy = Data(
      """
      {"tone":"简洁","alwaysInclude":"","alwaysAvoid":""}
      """.utf8
    )
    defaults.set(legacy, forKey: ProviderSettingsModel.writingPreferencesKey)
    let migrated = ProviderSettingsModel(
      credentialStore: FakeCredentialStore(),
      defaults: defaults
    )
    #expect(migrated.writingTone == "简洁")
    #expect(migrated.reportTaskInstructions == ChineseWorkReportPrompt.defaultTaskInstructions)
    #expect(migrated.reportOutputInstructions == ChineseWorkReportPrompt.defaultOutputInstructions)
  }

  private func makeDefaults() -> UserDefaults {
    let suite = "ProviderSettingsModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}

private actor FakeConnectionTester: ProviderConnectionTesting {
  private(set) var callCount = 0
  private(set) var lastCredential: String?

  func testConnection(
    configuration: OpenAICompatibleProviderConfiguration,
    credential: String
  ) async throws {
    callCount += 1
    lastCredential = credential
  }
}

private final class FakeCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
  var values: [String: String] = [:]

  func credential(for account: String) throws -> String? { values[account] }
  func save(_ credential: String, for account: String) throws { values[account] = credential }
  func removeCredential(for account: String) throws { values.removeValue(forKey: account) }
}
