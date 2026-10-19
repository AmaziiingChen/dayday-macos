import DaydayAI
import DaydayCore
import Foundation

/// Provider preferences exclude credentials. Debug builds use a local development credential store
/// to avoid Keychain prompts caused by ad-hoc signing; Release builds use the Keychain.
@MainActor
final class ProviderSettingsModel: ObservableObject {
  enum AccessError: Error {
    case invalidConfiguration
    case missingCredential
  }

  @Published var endpoint: String
  @Published var model: String
  @Published var thinkingEnabled: Bool
  @Published var reasoningEffort: OpenAICompatibleProviderConfiguration.ReasoningEffort
  @Published var apiKey = ""
  @Published private(set) var hasStoredCredential: Bool
  @Published private(set) var status = "尚未保存"
  @Published private(set) var isTestingConnection = false

  @Published var writingTone = ""
  @Published var writingAlwaysInclude = ""
  @Published var writingAlwaysAvoid = ""
  @Published var reportTaskInstructions = ChineseWorkReportPrompt.defaultTaskInstructions
  @Published var reportOutputInstructions = ChineseWorkReportPrompt.defaultOutputInstructions

  @Published var dailyTokenLimit: Int?
  @Published var monthlyTokenLimit: Int?

  private let credentialStore: any ProviderCredentialStoring
  private let connectionTester: any ProviderConnectionTesting
  private let defaults: UserDefaults
  private var reportGenerationSettingsChangeHandler:
    (@MainActor @Sendable (WorkReportTokenBudget, WorkReportWritingPreferences) -> Void)?
  private static let account = "deepseek"
  static let preferencesKey = "dayday.ai.openai-compatible.text-provider"
  static let writingPreferencesKey = "dayday.ai.openai-compatible.writing-preferences"
  static let budgetCapsKey = "dayday.ai.openai-compatible.budget-caps"
  static let dailyBudgetKey = "dayday.ai.openai-compatible.budget.daily"
  static let monthlyBudgetKey = "dayday.ai.openai-compatible.budget.monthly"

  init(
    credentialStore: (any ProviderCredentialStoring)? = nil,
    defaults: UserDefaults = .standard,
    developmentCredentialSource: (any DevelopmentCredentialImporting)? = nil,
    connectionTester: any ProviderConnectionTesting = OpenAICompatibleWorkReportClient()
  ) {
    self.credentialStore = credentialStore ?? AppCredentialStoreFactory.make(defaults: defaults)
    self.connectionTester = connectionTester
    self.defaults = defaults
    let configuration = Self.load(from: defaults) ?? .deepSeekDefault
    endpoint = configuration.endpoint.absoluteString
    model = configuration.model
    thinkingEnabled = configuration.thinkingEnabled
    reasoningEffort = configuration.reasoningEffort
    hasStoredCredential = (try? self.credentialStore.credential(for: Self.account)) != nil
    loadWritingPreferences()
    loadBudgetCaps()
    if !hasStoredCredential,
      let developmentCredentialSource,
      let credential = ProviderCredentialImport.oneTimeCredential(from: developmentCredentialSource)
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

  func testConnection() async {
    guard !isTestingConnection else { return }
    guard let configuration = currentConfiguration() else {
      status = "端点或模型无效"
      return
    }
    let credential: String
    do {
      guard let stored = try credentialStore.credential(for: Self.account), !stored.isEmpty else {
        status = "请先保存 API Key"
        return
      }
      credential = stored
    } catch {
      status = "无法读取已保存的 API Key"
      return
    }

    isTestingConnection = true
    status = "正在测试连接…"
    defer { isTestingConnection = false }
    do {
      try await connectionTester.testConnection(
        configuration: configuration,
        credential: credential
      )
      status = "连接成功，模型可用"
    } catch WorkReportProviderError.unauthorized {
      status = "认证失败，请检查 API Key"
    } catch WorkReportProviderError.configuredModelUnavailable {
      status = "连接成功，但当前模型不可用"
    } catch {
      status = "连接失败，请检查端点和网络"
    }
  }

  private func currentConfiguration() -> OpenAICompatibleProviderConfiguration? {
    guard let endpoint = URL(string: endpoint), endpoint.host != nil,
      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return OpenAICompatibleProviderConfiguration(
      endpoint: endpoint,
      model: model,
      thinkingEnabled: thinkingEnabled,
      reasoningEffort: reasoningEffort
    )
  }

  func configurationForPreview() throws -> OpenAICompatibleProviderConfiguration {
    guard let configuration = currentConfiguration() else {
      throw AccessError.invalidConfiguration
    }
    return configuration
  }

  func generationRequest() throws -> (
    configuration: OpenAICompatibleProviderConfiguration, credential: String
  ) {
    guard let configuration = currentConfiguration() else {
      throw AccessError.invalidConfiguration
    }
    guard let credential = try credentialStore.credential(for: Self.account), !credential.isEmpty
    else {
      throw AccessError.missingCredential
    }
    return (configuration, credential)
  }

  var currentWritingPreferences: WorkReportWritingPreferences {
    WorkReportWritingPreferences(
      tone: writingTone,
      alwaysInclude: writingAlwaysInclude,
      alwaysAvoid: writingAlwaysAvoid,
      taskInstructions: reportTaskInstructions,
      outputInstructions: reportOutputInstructions
    )
  }

  func setReportGenerationSettingsChangeHandler(
    _ handler: @escaping @MainActor @Sendable (
      WorkReportTokenBudget, WorkReportWritingPreferences
    ) -> Void
  ) {
    reportGenerationSettingsChangeHandler = handler
    publishReportGenerationSettings()
  }

  func saveWritingPreferences() {
    defaults.set(
      try? JSONEncoder().encode(currentWritingPreferences), forKey: Self.writingPreferencesKey
    )
    publishReportGenerationSettings()
  }

  func restoreDefaultReportPrompt() {
    reportTaskInstructions = ChineseWorkReportPrompt.defaultTaskInstructions
    reportOutputInstructions = ChineseWorkReportPrompt.defaultOutputInstructions
    saveWritingPreferences()
  }

  private func loadWritingPreferences() {
    guard let data = defaults.data(forKey: Self.writingPreferencesKey),
      let stored = try? JSONDecoder().decode(WorkReportWritingPreferences.self, from: data)
    else { return }
    writingTone = stored.tone
    writingAlwaysInclude = stored.alwaysInclude
    writingAlwaysAvoid = stored.alwaysAvoid
    reportTaskInstructions = stored.taskInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? ChineseWorkReportPrompt.defaultTaskInstructions
      : stored.taskInstructions
    reportOutputInstructions = stored.outputInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? ChineseWorkReportPrompt.defaultOutputInstructions
      : stored.outputInstructions
  }

  var currentBudget: WorkReportTokenBudget? {
    let daily: Int? = (dailyTokenLimit ?? 0) > 0 ? dailyTokenLimit : nil
    let monthly: Int? = (monthlyTokenLimit ?? 0) > 0 ? monthlyTokenLimit : nil
    return try? WorkReportTokenBudget(dailyLimit: daily, monthlyLimit: monthly)
  }

  func saveBudgetCaps() {
    defaults.set(dailyTokenLimit ?? -1, forKey: Self.dailyBudgetKey)
    defaults.set(monthlyTokenLimit ?? -1, forKey: Self.monthlyBudgetKey)
    publishReportGenerationSettings()
  }

  private func loadBudgetCaps() {
    let rawDaily = defaults.integer(forKey: Self.dailyBudgetKey)
    dailyTokenLimit = rawDaily > 0 ? rawDaily : nil
    let rawMonthly = defaults.integer(forKey: Self.monthlyBudgetKey)
    monthlyTokenLimit = rawMonthly > 0 ? rawMonthly : nil
  }

  private func publishReportGenerationSettings() {
    reportGenerationSettingsChangeHandler?(
      currentBudget ?? .unlimited,
      currentWritingPreferences
    )
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
    } catch { status = "无法保存 API Key" }
  }

  private static func load(from defaults: UserDefaults) -> OpenAICompatibleProviderConfiguration? {
    guard let data = defaults.data(forKey: preferencesKey) else { return nil }
    return try? JSONDecoder().decode(OpenAICompatibleProviderConfiguration.self, from: data)
  }
}
