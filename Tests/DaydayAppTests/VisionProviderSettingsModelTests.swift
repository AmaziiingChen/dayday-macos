import DaydayAI
import Foundation
import Testing

@testable import DaydayApp

@MainActor
struct VisionProviderSettingsModelTests {
  @Test
  func developmentCredentialStoreSeparatesVisionAndTextAccounts() throws {
    let defaults = makeDefaults()
    let store = DevelopmentCredentialStore(defaults: defaults)
    try store.save("text-key", for: "deepseek")
    try store.save("vision-key", for: VisionProviderSettingsModel.account)

    #expect(try store.credential(for: "deepseek") == "text-key")
    #expect(try store.credential(for: VisionProviderSettingsModel.account) == "vision-key")
  }

  @Test
  func savesQwenConfigurationAndKeepsCredentialOutOfPreferences() throws {
    let defaults = makeDefaults()
    let credentials = VisionCredentialStore()
    let model = VisionProviderSettingsModel(credentialStore: credentials, defaults: defaults)
    model.endpoint = "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    model.model = "qwen3-vl-flash"
    model.apiKey = "vision-test-key"

    model.save()

    #expect(credentials.values[VisionProviderSettingsModel.account] == "vision-test-key")
    let data = try #require(defaults.data(forKey: VisionProviderSettingsModel.preferencesKey))
    #expect(!String(decoding: data, as: UTF8.self).contains("vision-test-key"))
    let request = try model.runtimeRequest()
    #expect(request.configuration.model == "qwen3-vl-flash")
    #expect(request.configuration.thinkingEnabled == false)
  }

  @Test
  func connectionTestUsesDedicatedVisionCredential() async {
    let defaults = makeDefaults()
    let credentials = VisionCredentialStore()
    credentials.values[VisionProviderSettingsModel.account] = "vision-only-key"
    let tester = VisionConnectionTester()
    let model = VisionProviderSettingsModel(
      credentialStore: credentials,
      defaults: defaults,
      connectionTester: tester
    )
    let rearm = VisionRuntimeRearmRecorder()
    model.setConfigurationChangeHandler { request in
      rearm.credential = request?.credential
    }

    await model.testConnection()

    #expect(model.status == "连接成功，模型支持图像理解")
    #expect(await tester.lastModel == "qwen3-vl-flash")
    #expect(await tester.lastCredential == "vision-only-key")
    #expect(rearm.credential == "vision-only-key")
  }

  @Test
  func storedCredentialSurvivesModelRecreation() throws {
    let defaults = makeDefaults()
    let credentials = VisionCredentialStore()
    var first: VisionProviderSettingsModel? = VisionProviderSettingsModel(
      credentialStore: credentials, defaults: defaults)
    first?.apiKey = "persistent-vision-key"
    first?.save()
    first = nil

    let reopened = VisionProviderSettingsModel(
      credentialStore: credentials, defaults: defaults)

    #expect(reopened.hasStoredCredential)
    #expect(try reopened.runtimeRequest().credential == "persistent-vision-key")
    #expect(reopened.apiKey.isEmpty)
    #expect(
      reopened.status
        == "已加载保存的视觉配置（密钥仅存于\(AppCredentialStoreFactory.storageDescription)）"
    )
  }

  private func makeDefaults() -> UserDefaults {
    let suite = "VisionProviderSettingsModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}

private actor VisionConnectionTester: ScreenVisionConnectionTesting {
  private(set) var lastModel: String?
  private(set) var lastCredential: String?

  func testConnection(
    configuration: OpenAICompatibleVisionConfiguration,
    credential: String
  ) async throws {
    lastModel = configuration.model
    lastCredential = credential
  }
}

private final class VisionCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
  var values: [String: String] = [:]
  func credential(for account: String) throws -> String? { values[account] }
  func save(_ credential: String, for account: String) throws { values[account] = credential }
  func removeCredential(for account: String) throws { values.removeValue(forKey: account) }
}

private final class VisionRuntimeRearmRecorder: @unchecked Sendable {
  var credential: String?
}
