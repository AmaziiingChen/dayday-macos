import DaydayAI
import DaydayCore
import Foundation

@MainActor
final class JournalAIAssistantModel: ObservableObject {
  @Published private(set) var isGenerating = false
  @Published private(set) var status = "AI 写作已就绪"
  @Published private(set) var versions: [JournalDerivedVersion] = []
  @Published var preview: JournalDerivedVersion?

  private let journal: JournalEntryModel
  private let providerSettings: ProviderSettingsModel
  private let generator: any JournalAIGenerating
  private var repository: (any JournalDerivedVersionRepository)?
  private var lastOperation: JournalDerivedOperation?
  private var lastCustomInstruction: String?
  private var generationTask: Task<Void, Never>?
  private var generationGeneration = 0
  private var reloadGeneration = 0
  private var previewDayID: DayID?

  init(
    journal: JournalEntryModel,
    providerSettings: ProviderSettingsModel,
    generator: any JournalAIGenerating = OpenAICompatibleJournalClient()
  ) {
    self.journal = journal
    self.providerSettings = providerSettings
    self.generator = generator
  }

  deinit { generationTask?.cancel() }

  func configure(repository: any JournalDerivedVersionRepository) {
    self.repository = repository
  }

  func selectedDayDidChange() {
    reloadGeneration &+= 1
    generationGeneration &+= 1
    generationTask?.cancel()
    generationTask = nil
    isGenerating = false
    versions = []
    preview = nil
    previewDayID = nil
    status = "AI 写作已就绪"
  }

  func reload() async {
    guard let repository else { return }
    reloadGeneration &+= 1
    let generation = reloadGeneration
    let requestedDayID = journal.selectedDay?.id
    do {
      let record = try await journal.persistedRecordForSelectedDay()
      let loaded = try await repository.derivedVersions(for: record.entry.id, limit: 20)
      guard generation == reloadGeneration, journal.selectedDay?.id == requestedDayID else { return }
      versions = loaded
    } catch JournalEntryAIError.missingPersistedOriginal {
      versions = []
    } catch {
      status = "读取 AI 版本失败"
    }
  }

  func generate(
    operation: JournalDerivedOperation,
    customInstruction: String? = nil
  ) {
    guard !isGenerating else { return }
    generationTask?.cancel()
    generationGeneration &+= 1
    let generation = generationGeneration
    lastOperation = operation
    lastCustomInstruction = customInstruction
    isGenerating = true
    status = "正在生成独立 AI 版本…"
    generationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if generation == generationGeneration {
          isGenerating = false
        }
      }
      do {
        guard let repository else { throw JournalAIModelError.storageUnavailable }
        let record = try await journal.persistedRecordForDerivedOperation()
        let sourceDayID = record.day.id
        let provider = try providerSettings.generationRequest()
        let response = try await generator.generate(
          markdown: record.currentOriginal.body,
          operation: operation,
          customInstruction: customInstruction,
          configuration: provider.configuration,
          credential: provider.credential
        )
        try Task.checkCancellation()
        let provenance = try ModelProvenance(
          provider: provider.configuration.endpoint.host ?? "OpenAI-compatible",
          model: provider.configuration.model,
          promptVersion: OpenAICompatibleJournalClient.promptVersion
        )
        let version = try JournalDerivedVersion(
          journalEntryID: record.entry.id,
          sourceOriginalVersionID: record.currentOriginal.id,
          operation: operation,
          body: response.content,
          modelProvenance: provenance,
          createdAt: .now
        )
        _ = try await repository.saveDerivedVersion(version)
        guard generation == generationGeneration else { return }
        guard journal.selectedDay?.id == sourceDayID else {
          status = "日期已切换；生成结果已保存到原日期"
          return
        }
        versions.removeAll { $0.id == version.id }
        versions.insert(version, at: 0)
        preview = version
        previewDayID = sourceDayID
        status = "AI 版本已生成；正文尚未改变"
      } catch is CancellationError {
        guard generation == generationGeneration else { return }
        status = "已取消生成"
      } catch ProviderSettingsModel.AccessError.missingCredential {
        guard generation == generationGeneration else { return }
        status = "请先在设置中保存文本模型 API Key"
      } catch ProviderSettingsModel.AccessError.invalidConfiguration {
        guard generation == generationGeneration else { return }
        status = "请先在设置中配置文本模型"
      } catch WorkReportProviderError.unauthorized {
        guard generation == generationGeneration else { return }
        status = "模型认证失败，请检查 API Key"
      } catch WorkReportProviderError.rateLimited {
        guard generation == generationGeneration else { return }
        status = "模型请求过于频繁，请稍后再试"
      } catch {
        guard generation == generationGeneration else { return }
        status = "AI 生成失败；原日记未受影响"
      }
    }
  }

  func regenerate() {
    guard let lastOperation else { return }
    generate(operation: lastOperation, customInstruction: lastCustomInstruction)
  }

  func acceptPreview() {
    guard let preview, let previewDayID, journal.selectedDay?.id == previewDayID else {
      status = "日期已经切换，请回到原日期后再采纳"
      return
    }
    journal.acceptDerivedBody(preview.body)
    status = "已采纳到正文，并启用自动保存"
  }

  func present(_ version: JournalDerivedVersion) {
    preview = version
    previewDayID = journal.selectedDay?.id
  }
}

private enum JournalAIModelError: Error {
  case storageUnavailable
}

extension JournalDerivedOperation {
  var journalDisplayName: String {
    switch self {
    case .organize: "整理"
    case .rewrite: "改写"
    case .continueWriting: "续写"
    case .proofread: "校对"
    }
  }
}
