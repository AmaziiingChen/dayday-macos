import SwiftUI

struct RootView: View {
  @ObservedObject var runtime: AppRuntimeModel
  @ObservedObject var weather: WeatherRuntime
  @ObservedObject var dailyWorkScheduleSettings: DailyWorkScheduleSettingsModel
  @ObservedObject var inputInsights: InputInsightsModel
  @ObservedObject var applicationUsageInsights: ApplicationUsageInsightsModel
  @ObservedObject var permissionOnboarding: PermissionOnboardingModel
  @ObservedObject var appearance: AppearanceSettingsModel
  @ObservedObject var providerSettings: ProviderSettingsModel
  @ObservedObject var visionProviderSettings: VisionProviderSettingsModel
  @ObservedObject var diagnostics: PipelineDiagnosticsModel
  @ObservedObject var workReport: WorkReportGenerationModel
  @ObservedObject var historicalTimeline: HistoricalTimelineModel
  @ObservedObject var healthArchive: HealthArchiveModel
  @ObservedObject var journal: JournalEntryModel
  @ObservedObject var journalAI: JournalAIAssistantModel
  @ObservedObject var journalHistory: JournalHistoryModel
  @ObservedObject var journalFragments: JournalFragmentModel
  @ObservedObject var journalAttachments: JournalAttachmentModel
  @ObservedObject var journalLocations: JournalLocationModel
  @State private var selection: AppSection? = .today
  @State private var hasOpenedJournal = false
  @State private var hasOpenedReport = false

  var body: some View {
    NavigationSplitView {
      appSidebar
        .navigationSplitViewColumnWidth(min: 160, ideal: 196, max: 240)
    } detail: {
      retainedDetail
    }
    .navigationSplitViewStyle(.balanced)
    .sheet(
      isPresented: Binding(
        get: { permissionOnboarding.isFirstRunPresented },
        set: { if !$0 { permissionOnboarding.dismissFirstRun() } }
      )
    ) {
      PermissionOnboardingView(
        model: permissionOnboarding,
        presentation: .firstRun
      )
      .frame(width: 720, height: 560)
    }
    .onAppear {
      runtime.startMonitoring()
      runtime.setTodayTimelineVisible(selection == .today)
      permissionOnboarding.refreshSystemStatuses()
    }
    .onChange(of: selection) { _, nextSelection in
      runtime.setTodayTimelineVisible(nextSelection == .today)
      if nextSelection == .journal { hasOpenedJournal = true }
      if nextSelection == .report { hasOpenedReport = true }
    }
    .preferredColorScheme(appearance.preference.colorScheme)
    .environment(\.daydayAccent, appearance.accent)
    .accentColor(appearance.accent.tint)
    .tint(appearance.accent.tint)
    .animation(.easeOut(duration: 0.18), value: appearance.accent)
  }

  private var appSidebar: some View {
    List(AppSection.allCases, selection: $selection) { section in
      Label(section.title, systemImage: section.systemImage)
        .tag(section)
    }
    .listStyle(.sidebar)
    .daydayScrollIndicators()
    .navigationTitle("Dayday")
  }

  /// MarkEdit is a full local WebKit editor. Keep it mounted after the first
  /// visit so ordinary navigation never reloads its HTML, scripts, and process.
  @ViewBuilder
  private var retainedDetail: some View {
    ZStack {
      if selection != .journal, selection != .report {
        destination(for: selection ?? .today)
      }

      if hasOpenedReport || selection == .report {
        destination(for: .report)
          .opacity(selection == .report ? 1 : 0)
          .allowsHitTesting(selection == .report)
          .accessibilityHidden(selection != .report)
      }

      if hasOpenedJournal || selection == .journal {
        destination(for: .journal)
          .opacity(selection == .journal ? 1 : 0)
          .allowsHitTesting(selection == .journal)
          .accessibilityHidden(selection != .journal)
      }
    }
  }

  @ViewBuilder
  private func destination(for section: AppSection) -> some View {
    switch section {
    case .today:
      TodayView(
        runtime: runtime,
        weather: weather,
        dailyWorkScheduleSettings: dailyWorkScheduleSettings,
        input: inputInsights,
        applicationUsage: applicationUsageInsights,
        onOpenHistory: {
          historicalTimeline.showCurrentDay()
          selection = .history
        },
        onOpenInsights: { selection = .insights }
      )
    case .report:
      DailyReportView(
        weather: weather,
        workReport: workReport,
        isActive: selection == .report,
        onOpenHistory: { selection = .history }
      )
    case .journal:
      JournalView(
        journal: journal,
        journalAI: journalAI,
        history: journalHistory,
        journalFragments: journalFragments,
        attachments: journalAttachments,
        locations: journalLocations,
        weather: weather,
        isActive: selection == .journal
      )
    case .history:
      HistoryView(workReport: workReport, timeline: historicalTimeline)
    case .health:
      HealthArchiveView(archive: healthArchive)
    case .insights:
      InsightsView(
        input: inputInsights,
        runtime: runtime,
        dailyWorkScheduleSettings: dailyWorkScheduleSettings,
        applicationUsage: applicationUsageInsights
      )
    case .settings:
      SettingsView(
        runtime: runtime,
        permissionOnboarding: permissionOnboarding,
        dailyWorkScheduleSettings: dailyWorkScheduleSettings,
        providerSettings: providerSettings,
        visionProviderSettings: visionProviderSettings, diagnostics: diagnostics,
        workReport: workReport,
        weather: weather,
        appearance: appearance,
        openHistory: { selection = .history }
      )
    }
  }
}

extension AppRuntimeModel.CollectionStatus {
  var title: String {
    switch self {
    case .checking: "正在检查本机状态"
    case .notConfigured: "Dayday 尚未开始记录"
    case .starting: "正在安全启动本地记录"
    case .running: "Dayday 正在记录本机客观事实"
    case .paused: "Dayday 已暂停"
    case .permissionRequired: "系统权限尚未完整授权"
    case .disabled: "应用窗口记录尚未启用"
    case .degraded: "记录已安全降级"
    case .failed: "本地记录未能启动"
    }
  }

  var detail: String {
    switch self {
    case .checking: "仅读取权限与显示器元数据，不会弹出授权窗口"
    case .notConfigured: "正在等待你在设置中确认允许的采集项"
    case .starting: "正在核对本地存储、控制状态与系统授权；不会弹出权限窗口"
    case .running: "只写入经过隐私过滤的本机客观事实；关闭窗口不会停止记录"
    case .paused: "恢复后才会继续采集"
    case .permissionRequired: "请完成右侧标记为尚未授权的系统权限"
    case .disabled: "启用并完成所需权限后，Dayday 才会开始记录"
    case .degraded: "采集已停止或受限；请检查设置后重试"
    case .failed: "本地记录暂未启动；请在设置的“运行诊断”中查看原因后重试。"
    }
  }

  var symbolName: String {
    switch self {
    case .checking: "arrow.triangle.2.circlepath"
    case .notConfigured: "circle.dashed"
    case .starting: "arrow.triangle.2.circlepath.circle"
    case .running: "record.circle.fill"
    case .paused: "pause.circle.fill"
    case .permissionRequired: "exclamationmark.circle.fill"
    case .disabled: "power.circle"
    case .degraded: "exclamationmark.triangle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  var color: Color {
    switch self {
    case .checking, .notConfigured, .starting: .secondary
    case .running: .green
    case .paused: .orange
    case .permissionRequired, .disabled, .degraded: .orange
    case .failed: .red
    }
  }
}
