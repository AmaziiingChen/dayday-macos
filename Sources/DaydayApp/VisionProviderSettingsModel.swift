import DaydayAI
import Foundation

/// Visual inference has its own endpoint, model and credential. It must never reuse the work-report
/// credential implicitly because the two providers may have different data and budget policies.
@MainActor
final class VisionProviderSettingsModel: ObservableObject {
  enum AccessError: Error {
    case invalidConfiguration
    case missingCredential
  }

  static let account = "screen-vision"
  static let preferencesKey = "dayday.ai.openai-compatible.vision-provider"
  static let defaultConfiguration = OpenAICompatibleVisionConfiguration(
    endpoint: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
    model: "qwen3-vl-flash",
    detail: .high,
    thinkingEnabled: false
  )

  @Published var endpoint: String
  @Published var model: String
  @Published var detail: OpenAICompatibleVisionConfiguration.Detail
  @Published var apiKey = ""
  @Published private(set) var hasStoredCredential: Bool
  @Published private(set) var status = "尚未保存"
  @Published private(set) var isTestingConnection = false

  private let credentialStore: any ProviderCredentialStoring
  private let connectionTester: any ScreenVisionConnectionTesting
  private let defaults: UserDefaults
  private var configurationChangeHandler: (@Sendable (RuntimeRequest?) -> Void)?

  struct RuntimeRequest: Sendable {
    let configuration: OpenAICompatibleVisionConfiguration
    let credential: String
  }

  init(
    credentialStore: (any ProviderCredentialStoring)? = nil,
    defaults: UserDefaults = .standard,
    developmentCredentialSource: (any DevelopmentCredentialImporting)? = nil,
    connectionTester: any ScreenVisionConnectionTesting = OpenAICompatibleScreenVisionClient()
  ) {
    self.credentialStore = credentialStore ?? AppCredentialStoreFactory.make(defaults: defaults)
    self.connectionTester = connectionTester
    self.defaults = defaults
    let configuration = Self.load(from: defaults) ?? Self.defaultConfiguration
    endpoint = configuration.endpoint.absoluteString
    model = configuration.model
    detail = configuration.detail
    hasStoredCredential = (try? self.credentialStore.credential(for: Self.account)) != nil

    if hasStoredCredential {
      status = "已加载保存的视觉配置（密钥仅存于\(AppCredentialStoreFactory.storageDescription)）"
    }

    if !hasStoredCredential,
      let developmentCredentialSource,
      let credential = ProviderCredentialImport.oneTimeCredential(
        from: developmentCredentialSource,
        name: "DAYDAY_VISION_API_KEY"
      )
    {
      do {
        try self.credentialStore.save(credential, for: Self.account)
        hasStoredCredential = true
        status = "已从开发环境导入密钥（仅存于\(AppCredentialStoreFactory.storageDescription)）"
      } catch {
        status = "无法导入开发密钥"
      }
    }
  }

  func setConfigurationChangeHandler(
    _ handler: (@Sendable (RuntimeRequest?) -> Void)?
  ) {
    configurationChangeHandler = handler
  }

  func runtimeRequest() throws -> RuntimeRequest {
    guard let configuration = currentConfiguration() else {
      throw AccessError.invalidConfiguration
    }
    guard let credential = try credentialStore.credential(for: Self.account), !credential.isEmpty
    else { throw AccessError.missingCredential }
    return RuntimeRequest(configuration: configuration, credential: credential)
  }

  func save() {
    guard let configuration = currentConfiguration() else {
      status = "端点或模型无效"
      return
    }
    do {
      if !apiKey.isEmpty {
        try credentialStore.save(apiKey, for: Self.account)
        apiKey = ""
        hasStoredCredential = true
      }
      defaults.set(try JSONEncoder().encode(configuration), forKey: Self.preferencesKey)
      status =
        hasStoredCredential
        ? "已保存（密钥仅在\(AppCredentialStoreFactory.storageDescription)中）"
        : "已保存端点与模型；仍需填写密钥"
      configurationChangeHandler?(try? runtimeRequest())
    } catch {
      status = "无法保存 API Key"
    }
  }

  func testConnection() async {
    guard !isTestingConnection else { return }
    let request: RuntimeRequest
    do {
      request = try runtimeRequest()
    } catch AccessError.invalidConfiguration {
      status = "端点或模型无效"
      return
    } catch {
      status = "请先保存 API Key"
      return
    }

    isTestingConnection = true
    status = "正在测试图像输入与 JSON 输出…"
    defer { isTestingConnection = false }
    do {
      try await connectionTester.testConnection(
        configuration: request.configuration,
        credential: request.credential
      )
      status = "连接成功，模型支持图像理解"
      // A successful explicit test is also the user's signal to re-arm a runtime that stopped
      // after an authentication failure (for example, after replenishing provider credit).
      configurationChangeHandler?(request)
    } catch ScreenVisionProviderError.unauthorized {
      status = "认证失败，请检查 API Key"
    } catch ScreenVisionProviderError.rateLimited {
      status = "连接成功但触发限流，请稍后重试"
    } catch ScreenVisionProviderError.rejected {
      status = "模型拒绝请求，请检查模型名称与图像权限"
    } catch {
      status = "连接失败，请检查端点、模型和网络"
    }
  }

  private func currentConfiguration() -> OpenAICompatibleVisionConfiguration? {
    guard let endpoint = URL(string: endpoint), endpoint.host != nil,
      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return OpenAICompatibleVisionConfiguration(
      endpoint: endpoint,
      model: model,
      detail: detail,
      thinkingEnabled: false
    )
  }

  private static func load(from defaults: UserDefaults) -> OpenAICompatibleVisionConfiguration? {
    guard let data = defaults.data(forKey: preferencesKey) else { return nil }
    return try? JSONDecoder().decode(OpenAICompatibleVisionConfiguration.self, from: data)
  }
}
