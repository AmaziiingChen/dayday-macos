import Combine
import DaydayCore
import Foundation

@MainActor
final class PipelineDiagnosticsModel: ObservableObject {
  @Published private(set) var isRefreshing = false
  @Published private(set) var objectiveTextCount = 0
  @Published private(set) var inferenceCount = 0
  @Published private(set) var textAggregateCount = 0
  @Published private(set) var latestObjectiveTextAt: Date?
  @Published private(set) var latestInferenceAt: Date?
  @Published private(set) var visionUsage = ScreenVisionUsageSummary(
    callCount: 0, successCount: 0, inputTokens: 0, outputTokens: 0,
    cachedInputTokens: 0, totalTokens: 0, failuresByCategory: [:]
  )
  @Published private var chromeState: BrowserBridgeDiagnosticState?
  @Published private var tabbitState: BrowserBridgeDiagnosticState?
  @Published private(set) var failureDescription = ""
  @Published private(set) var visualAnchorDescription = "尚未收到识别锚点"
  @Published private(set) var visualSegmentDescription = "尚未完成结构化视觉片段"
  @Published private(set) var lastRefreshedAt: Date?

  private var visibleContent: (any VisibleContentArchiveRepository)?
  private var textProduction: (any TextProductionAggregateRepository)?
  private var visionUsageRepository: (any ScreenVisionUsageRepository)?
  private var refreshTask: Task<Void, Never>?

  func configure(
    visibleContent: any VisibleContentArchiveRepository,
    textProduction: any TextProductionAggregateRepository,
    visionUsage: any ScreenVisionUsageRepository
  ) {
    self.visibleContent = visibleContent
    self.textProduction = textProduction
    visionUsageRepository = visionUsage
    refresh()
  }

  func applyScreenVisionTrace(_ trace: ScreenVisionRuntime.Trace) {
    let anchor = switch trace.lastAnchor {
    case .applicationContextChanged: "应用/窗口状态变化"
    case .submission: "回车或数字键盘 Enter"
    case nil: "周期性采样"
    }
    let pending = trace.pendingTimeSliceCount == 0 ? "无待处理时片" : "\(trace.pendingTimeSliceCount) 个待处理时片"
    visualAnchorDescription = "\(anchor) · \(pending)"

    let transition = switch trace.lastTransition {
    case .opened: "新建可见片段"
    case .continued: "延续上一片段"
    case .changed: "状态已变化，切分新片段"
    case .uncertain: "连续性不确定，等待后续观察"
    case nil: "尚未完成结构化视觉片段"
    }
    let completed = trace.lastCompletedAt.map {
      " · 最近 \($0.formatted(date: .omitted, time: .standard))"
    } ?? ""
    let failureStage: String? = switch trace.lastFailureStage {
    case .configuration: "配置校验"
    case .providerRequest: "模型请求"
    case .responseValidation: "响应校验"
    case .localAcceptance: "本地接纳"
    case nil: nil
    }
    let failure = trace.lastFailureCategory.map {
      " · 最近失败：\(failureStage.map { "\($0) / " } ?? "")\($0.rawValue)"
    } ?? ""
    visualSegmentDescription = "\(transition)\(completed)\(failure)"
  }

  func refresh() {
    guard refreshTask == nil else { return }
    guard let visibleContent, let textProduction, let visionUsageRepository else {
      failureDescription = "本地生产存储尚未就绪"
      return
    }
    isRefreshing = true
    let range = Date().addingTimeInterval(-24 * 60 * 60)..<Date().addingTimeInterval(1)
    refreshTask = Task { [weak self] in
      defer {
        self?.isRefreshing = false
        self?.refreshTask = nil
      }
      do {
        async let content = visibleContent.fetchVisibleContent(observedIn: range)
        async let text = textProduction.fetchTextProduction(observedIn: range)
        async let usage = visionUsageRepository.screenVisionUsage(in: range)
        let (observations, aggregates, usageSummary) = try await (content, text, usage)
        guard !Task.isCancelled else { return }
        self?.objectiveTextCount = observations.filter { $0.kind == .objectiveText }.count
        self?.inferenceCount = observations.filter { $0.kind == .inference }.count
        self?.textAggregateCount = aggregates.count
        self?.latestObjectiveTextAt =
          observations.last(where: { $0.kind == .objectiveText })?
          .provenance.observedAt
        self?.latestInferenceAt =
          observations.last(where: { $0.kind == .inference })?
          .provenance.observedAt
        self?.visionUsage = usageSummary
        self?.chromeState = Self.browserState(bundleIdentifier: "com.google.chrome")
        self?.tabbitState = Self.browserState(bundleIdentifier: "com.tab-browser.tabbit")
        self?.failureDescription = ""
        self?.lastRefreshedAt = Date()
      } catch {
        self?.failureDescription = "诊断读取失败，请检查本地存储后重试。"
      }
    }
  }

  var summaryTitle: String {
    inferenceCount > 0 && visionUsage.successCount > 0 ? "采集与视觉理解正在产出" : "正在等待完整管线产出"
  }

  var summaryDetail: String { "最近 24 小时的本机只读诊断" }
  var lastRefreshDescription: String {
    guard let lastRefreshedAt else { return "" }
    return "最近刷新：\(lastRefreshedAt.formatted(date: .omitted, time: .standard))"
  }
  var objectiveTextDescription: String {
    countDescription(objectiveTextCount, latest: latestObjectiveTextAt)
  }
  var visualInferenceDescription: String {
    countDescription(inferenceCount, latest: latestInferenceAt)
  }
  var textProductionDescription: String { "\(textAggregateCount) 个聚合区间" }
  var visionUsageDescription: String {
    let stageLabels: [ScreenVisionFailureStage: String] = [
      .configuration: "配置", .providerRequest: "请求", .responseValidation: "响应校验",
      .localAcceptance: "本地接纳",
    ]
    let failures = visionUsage.failuresByStage
      .sorted { $0.key.rawValue < $1.key.rawValue }
      .map { "\(stageLabels[$0.key] ?? $0.key.rawValue) \($0.value)" }
      .joined(separator: "、")
    let failureDescription = failures.isEmpty ? "" : " · 失败：\(failures)"
    return "\(visionUsage.successCount)/\(visionUsage.callCount) 成功 · \(visionUsage.totalTokens) tokens\(failureDescription)"
  }
  var chromeDescription: String { browserDescription(chromeState) }
  var tabbitDescription: String { browserDescription(tabbitState) }

  private func countDescription(_ count: Int, latest: Date?) -> String {
    guard let latest else { return "\(count) 条" }
    return "\(count) 条 · 最近 \(latest.formatted(date: .omitted, time: .standard))"
  }

  private func browserDescription(_ state: BrowserBridgeDiagnosticState?) -> String {
    guard let state else { return "未收到状态" }
    let freshness = Date().timeIntervalSince(state.observedAt) <= 90 ? "在线" : "状态过期"
    if state.incognito { return "\(freshness) · 无痕窗口已隔离" }
    return state.bridgeReady ? "\(freshness) · 可接收扩展状态" : "\(freshness) · 桥接未就绪"
  }

  private static func browserState(bundleIdentifier: String) -> BrowserBridgeDiagnosticState? {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayday/BrowserBridge", isDirectory: true)
    let url = base.appendingPathComponent("\(bundleIdentifier).json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(BrowserBridgeDiagnosticState.self, from: data)
  }
}

private struct BrowserBridgeDiagnosticState: Decodable, Sendable {
  let bridgeReady: Bool
  let incognito: Bool
  let observedAt: Date
}
