import DaydayAI
import DaydayCore
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
  case appearance
  case collection
  case report
  case models
  case storage
  case diagnostics

  var id: Self { self }

  var title: String {
    switch self {
    case .appearance: "外观"
    case .collection: "采集状态"
    case .report: "时间与日报"
    case .models: "模型与用量"
    case .storage: "数据与存储"
    case .diagnostics: "运行诊断"
    }
  }

  var systemImage: String {
    switch self {
    case .appearance: "circle.lefthalf.filled"
    case .collection: "dot.radiowaves.left.and.right"
    case .report: "clock.badge.checkmark"
    case .models: "sparkles"
    case .storage: "externaldrive"
    case .diagnostics: "stethoscope"
    }
  }
}

private enum ReportRequestPreviewSection: String, CaseIterable, Identifiable {
  case system = "系统提示词"
  case user = "上下文消息"
  case context = "上下文 JSON"
  case request = "完整请求体"

  var id: Self { self }
}

/// Settings chooses its secondary navigation from the detail column's actual
/// width. Measuring a vertically-and-horizontally scrollable request preview
/// made `ViewThatFits` treat its long source text as the page's minimum width,
/// so opening Time & Reports could unexpectedly collapse or spill its parent.
enum SettingsContentLayout: Equatable {
  /// The secondary settings sidebar needs room for its 168 pt column, the
  /// inter-column gutter, and a usable detail column. Keeping it at the old
  /// 720 pt cutoff squeezed the detail area and let it intrude into the app
  /// sidebar instead of switching to the native category menu.
  static let minimumRegularWidth: CGFloat = 860

  case regular
  case compact

  init(availableWidth: CGFloat) {
    self = availableWidth >= Self.minimumRegularWidth ? .regular : .compact
  }
}

struct SettingsView: View {
  @ObservedObject var runtime: AppRuntimeModel
  @ObservedObject var permissionOnboarding: PermissionOnboardingModel
  @ObservedObject var dailyWorkScheduleSettings: DailyWorkScheduleSettingsModel
  @ObservedObject var providerSettings: ProviderSettingsModel
  @ObservedObject var visionProviderSettings: VisionProviderSettingsModel
  @ObservedObject var diagnostics: PipelineDiagnosticsModel
  @ObservedObject var workReport: WorkReportGenerationModel
  @ObservedObject var weather: WeatherRuntime
  @ObservedObject var appearance: AppearanceSettingsModel
  let openHistory: () -> Void

  @State private var selectedSection: SettingsSection = .collection
  @State private var reportRequestPreviewSection: ReportRequestPreviewSection = .system
  @StateObject private var storage = LocalStorageSettingsModel()

  var body: some View {
    VStack(spacing: 0) {
      PageHeaderBar(title: "设置", subtitle: nil, systemImage: "gearshape")

      settingsBody
      .padding(.horizontal, DaydaySpace.pageHorizontal)
      .padding(.top, DaydaySpace.pageContentTop)
      .padding(.bottom, DaydaySpace.pageHorizontal)
      .frame(maxHeight: .infinity, alignment: .top)
      .frame(maxWidth: 1120, alignment: .topLeading)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  /// Keep the familiar settings subnavigation at normal widths, but never let
  /// it compete with the app sidebar and the content column in a narrow window.
  private var settingsBody: some View {
    GeometryReader { proxy in
      Group {
        if SettingsContentLayout(availableWidth: proxy.size.width) == .regular {
          regularSettingsBody
        } else {
          compactSettingsBody
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 0)
    .frame(maxWidth: 1120, maxHeight: .infinity, alignment: .topLeading)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var regularSettingsBody: some View {
    HStack(alignment: .top, spacing: DaydaySpace.xl) {
      settingsNavigation
        .frame(width: 168, alignment: .topLeading)
      settingsContentScroll
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        .layoutPriority(1)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
  }

  private var compactSettingsBody: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.m) {
      HStack(spacing: DaydaySpace.s) {
        Text("设置分类")
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker("设置分类", selection: $selectedSection) {
          ForEach(SettingsSection.allCases) { section in
            Label(section.title, systemImage: section.systemImage)
              .tag(section)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        Spacer(minLength: 0)
      }
      .frame(minHeight: 30, alignment: .leading)

      settingsContentScroll
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var settingsNavigation: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(SettingsSection.allCases) { section in
        Button {
          selectedSection = section
        } label: {
          HStack(spacing: 10) {
            Image(systemName: section.systemImage)
              .frame(width: 20)
              .accessibilityHidden(true)
            Text(section.title)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(
            selectedSection == section ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var settingsContentScroll: some View {
    DaydayScrollView {
      selectedContent
        .frame(minWidth: 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.trailing, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var selectedContent: some View {
    switch selectedSection {
    case .appearance:
      appearancePage
    case .collection:
      collectionPage
    case .report:
      reportPage
    case .models:
      modelAndUsagePage
    case .storage:
      storagePage
    case .diagnostics:
      diagnosticsPage
    }
  }

  private var collectionPage: some View {
    VStack(alignment: .leading, spacing: 18) {
      PermissionOnboardingView(
        model: permissionOnboarding,
        presentation: .settings
      )
    }
  }

  private var appearancePage: some View {
    DaydayCard("外观", systemImage: "circle.lefthalf.filled") {
      Text("选择 Dayday 的显示外观。跟随系统会同步 macOS 外观，并保留系统的辅助功能显示设置。")
        .font(.callout)
        .foregroundStyle(.secondary)

      Picker("外观", selection: $appearance.preference) {
        ForEach(AppearanceSettingsModel.Preference.allCases) { preference in
          Text(preference.title).tag(preference)
        }
      }
      .pickerStyle(.segmented)

      VStack(alignment: .leading, spacing: 9) {
        Text("主题色")
          .font(.callout.weight(.medium))
        HStack(spacing: 10) {
          ForEach(AppearanceSettingsModel.Accent.allCases) { accent in
            Button {
              appearance.accent = accent
            } label: {
              VStack(spacing: 6) {
                ZStack {
                  Circle()
                    .fill(accent.tint)
                  if appearance.accent == accent {
                    Image(systemName: "checkmark")
                      .font(.caption.weight(.bold))
                      .foregroundStyle(.white)
                  }
                }
                .frame(width: 30, height: 30)
                Text(accent.title)
                  .font(.caption2)
                  .foregroundStyle(.primary)
              }
              .frame(width: 58)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("主题色：\(accent.title)")
            .accessibilityAddTraits(appearance.accent == accent ? .isSelected : [])
          }
        }
      }

      Text(appearanceDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var appearanceDetail: String {
    switch appearance.preference {
    case .system: "当前会跟随 macOS 的浅色或深色外观。"
    case .light: "已固定为浅色外观，会立即作用于主窗口与菜单栏仪表盘。"
    case .dark: "已固定为深色外观，会立即作用于主窗口与菜单栏仪表盘。"
    }
  }

  private var reportPage: some View {
    VStack(alignment: .leading, spacing: 18) {
      DaydayCard("时间与工作日", systemImage: "clock") {
        Text("这四项是本机的明文配置。上班、下班用于表达你的工作节奏；日报时间用于自动生成；新一天起点同时决定“今日”时间线和日报的日期归属。")
          .font(.callout)
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 12) {
          scheduleTimeRow(
            "上班时间",
            hour: $dailyWorkScheduleSettings.workStartHour,
            minute: $dailyWorkScheduleSettings.workStartMinute
          )
          scheduleTimeRow(
            "下班时间",
            hour: $dailyWorkScheduleSettings.workEndHour,
            minute: $dailyWorkScheduleSettings.workEndMinute
          )
          scheduleTimeRow(
            "日报生成时间",
            hour: $dailyWorkScheduleSettings.reportHour,
            minute: $dailyWorkScheduleSettings.reportMinute
          )
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
              Text("新一天起点")
                .frame(width: 92, alignment: .leading)
            Picker("新一天起点", selection: $dailyWorkScheduleSettings.boundaryHour) {
              ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour)
              }
            }
            .labelsHidden()
            .frame(width: 112)
            }
            Text("默认 04:00；可改为 00:00 等整点")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        ViewThatFits(in: .horizontal) {
          HStack {
            scheduleActionButtons
            Spacer(minLength: 12)
            scheduleStatus
          }
          VStack(alignment: .leading, spacing: 8) {
            scheduleActionButtons
            scheduleStatus
          }
        }
      }

      DaydayCard("日报生成管线", systemImage: "point.3.connected.trianglepath.dotted") {
        reportDetailRow("运行流程", "确定工作日 → 检查证据覆盖 → 压缩上下文 → 调用模型 → 原子保存来源与修订 → 新事实增量补写")
        reportDetailRow("当前输入", "客观应用片段、H2 Activity、AI 视觉摘要、工作备注、当日区级天气")
        reportDetailRow("明确排除", "日历、提醒、待办、日记、心情、附件、精确位置")
        reportDetailRow("日报推理", "关闭深度思考；正文最多 4096 tokens")
        reportDetailRow("晚到事实", "证据连续 10 分钟稳定后追加 AI 修订；不覆盖人工版本")
        reportDetailRow("证据覆盖", workReport.evidenceCoverage.statusText)
        Text("群名、联系人和聊天可见内容沿用已允许的来源原文，日报管线不增加二次安全过滤。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("“今日”页仍只展示当天时间线；日报页仍只编辑和管理日报，二者不做界面串联。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      writingPreferencesCard

      DaydayCard("提交给模型的实际内容", systemImage: "doc.text.magnifyingglass") {
        Text("预览使用当前工作日、当前工作备注和当日天气组装与生成按钮相同的请求。它不读取 API Key、不调用模型、不保存预览。")
          .font(.callout)
          .foregroundStyle(.secondary)

        HStack {
          Button("刷新实际请求预览", systemImage: "arrow.clockwise") {
            refreshReportRequestPreview()
          }
          Spacer()
          Text(workReport.requestPreviewStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let preview = workReport.requestPreview {
          reportDetailRow("目标", "\(preview.endpoint.absoluteString)  ·  \(preview.model)")
          Picker("预览内容", selection: $reportRequestPreviewSection) {
            ForEach(ReportRequestPreviewSection.allCases) { section in
              Text(section.rawValue).tag(section)
            }
          }
          .pickerStyle(.segmented)

          ScrollView([.vertical, .horizontal]) {
            Text(reportRequestPreviewText(preview))
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(10)
          }
          .frame(maxWidth: .infinity)
          .frame(minHeight: 220, maxHeight: 360)
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(Color.secondary.opacity(0.2))
          }
        }
      }
    }
    .task {
      if workReport.requestPreview == nil {
        refreshReportRequestPreview()
      }
    }
  }

  private func scheduleTimeRow(
    _ title: String,
    hour: Binding<Int>,
    minute: Binding<Int>
  ) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .frame(width: 92, alignment: .leading)
      HStack(spacing: 6) {
        Picker("小时", selection: hour) {
          ForEach(0..<24, id: \.self) { value in
            Text(String(format: "%02d", value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 72)
        Text(":")
        Picker("分钟", selection: minute) {
          ForEach(0..<60, id: \.self) { value in
            Text(String(format: "%02d", value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 72)
      }
    }
  }

  private var scheduleActionButtons: some View {
    HStack(spacing: 10) {
      Button("保存时间配置", action: dailyWorkScheduleSettings.save)
      Button("恢复默认") {
        dailyWorkScheduleSettings.restoreDefaults()
      }
    }
  }

  private var scheduleStatus: some View {
    Text(dailyWorkScheduleSettings.status)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func reportDetailRow(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func refreshReportRequestPreview() {
    let weatherSnapshot = workReport.dayDescriptor().flatMap(weather.workReportSnapshot)
    Task {
      await workReport.refreshRequestPreview(
        workNote: "",
        weatherSnapshot: weatherSnapshot
      )
    }
  }

  private func reportRequestPreviewText(_ preview: WorkReportRequestPreview) -> String {
    switch reportRequestPreviewSection {
    case .system: preview.systemPrompt
    case .user: preview.userMessage
    case .context: preview.contextJSON
    case .request: preview.requestBodyJSON
    }
  }

  private var modelAndUsagePage: some View {
    VStack(alignment: .leading, spacing: 18) {
      DaydayCard("日报文本模型", systemImage: "text.sparkle") {
        Text("用于生成日报。它只接收工作报告允许的结构化上下文，不读取日记或心情记录。")
          .font(.callout)
          .foregroundStyle(.secondary)
        modelCredentialState(
          hasCredential: providerSettings.hasStoredCredential,
          status: providerSettings.status
        )
        TextField("Endpoint", text: $providerSettings.endpoint)
        TextField("Model", text: $providerSettings.model)
        SecureField(
          "API Key（仅保存到\(AppCredentialStoreFactory.storageDescription)）",
          text: $providerSettings.apiKey
        )
        Toggle("启用思考", isOn: $providerSettings.thinkingEnabled)
        Picker("推理强度", selection: $providerSettings.reasoningEffort) {
          ForEach(OpenAICompatibleProviderConfiguration.ReasoningEffort.allCases, id: \.self) {
            effort in
            Text(effort.rawValue).tag(effort)
          }
        }
        modelActions(
          isTesting: providerSettings.isTestingConnection,
          save: providerSettings.save,
          test: providerSettings.testConnection
        )
      }

      DaydayCard("屏幕理解视觉模型", systemImage: "eye") {
        Text("用于解析屏幕证据与近期工作状态；独立于日报文本模型配置。")
          .font(.callout)
          .foregroundStyle(.secondary)
        modelCredentialState(
          hasCredential: visionProviderSettings.hasStoredCredential,
          status: visionProviderSettings.status
        )
        TextField("Endpoint", text: $visionProviderSettings.endpoint)
        TextField("Model", text: $visionProviderSettings.model)
        SecureField(
          "API Key（仅保存到\(AppCredentialStoreFactory.storageDescription)）",
          text: $visionProviderSettings.apiKey
        )
        Picker("图像细节", selection: $visionProviderSettings.detail) {
          ForEach(OpenAICompatibleVisionConfiguration.Detail.allCases, id: \.self) { detail in
            Text(detail.rawValue).tag(detail)
          }
        }
        modelActions(
          isTesting: visionProviderSettings.isTestingConnection,
          save: visionProviderSettings.save,
          test: visionProviderSettings.testConnection
        )
      }

      usageAndBudgetCard
    }
    .task {
      await workReport.refreshUsageStatistics()
      diagnostics.refresh()
    }
  }

  private func modelCredentialState(hasCredential: Bool, status: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      StatusBadge(
        title: hasCredential ? "密钥已保存" : "尚未保存密钥",
        systemImage: hasCredential ? "key.fill" : "key.slash",
        color: hasCredential ? .green : .secondary
      )
      Text(status)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  private func modelActions(
    isTesting: Bool,
    save: @escaping () -> Void,
    test: @escaping () async -> Void
  ) -> some View {
    HStack {
      Button("保存", action: save)
      Button(isTesting ? "正在测试…" : "保存并测试") {
        save()
        Task { await test() }
      }
      .disabled(isTesting)
      Spacer()
      Text("测试使用已保存的配置与密钥")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var writingPreferencesCard: some View {
    DaydayCard("日报提示词与输出", systemImage: "text.alignleft") {
      Text("任务要求和输出要求可编辑。事实性、来源边界、日记隔离与提示词注入防护是固定系统边界，不会被这里的文字覆盖。")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("任务要求")
        .font(.callout.weight(.medium))
      TextEditor(text: $providerSettings.reportTaskInstructions)
        .font(.body)
        .frame(minHeight: 150)
        .overlay {
          RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2))
        }
      Text("输出要求")
        .font(.callout.weight(.medium))
      TextEditor(text: $providerSettings.reportOutputInstructions)
        .font(.body)
        .frame(minHeight: 110)
        .overlay {
          RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2))
        }
      TextField("语气与风格", text: $providerSettings.writingTone)
      TextField("尽量包含", text: $providerSettings.writingAlwaysInclude)
      TextField("不要写入", text: $providerSettings.writingAlwaysAvoid)
      HStack {
        Button("保存提示词与偏好") {
          providerSettings.saveWritingPreferences()
          refreshReportRequestPreview()
        }
        Button("恢复默认提示词") {
          providerSettings.restoreDefaultReportPrompt()
          refreshReportRequestPreview()
        }
        Spacer()
        Text("保存后用于下次生成")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var usageAndBudgetCard: some View {
    DaydayCard("模型用量与预算", systemImage: "chart.bar.doc.horizontal") {
      Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
        GridRow {
          MetricView(
            value: "\(workReport.usageSummary.totalTokens)",
            label: "今日日报 tokens"
          )
          MetricView(
            value: "\(workReport.monthlyUsageSummary.totalTokens)",
            label: "本月日报 tokens"
          )
          MetricView(
            value: "\(diagnostics.visionUsage.totalTokens)",
            label: "近 24 小时视觉 tokens"
          )
        }
      }
      TextField("日报日预算上限（token，留空 = 不限）", value: $providerSettings.dailyTokenLimit, format: .number)
      TextField("日报月预算上限（token，留空 = 不限）", value: $providerSettings.monthlyTokenLimit, format: .number)
      HStack {
        Button("保存预算", action: providerSettings.saveBudgetCaps)
        Spacer()
        Button("刷新用量", systemImage: "arrow.clockwise") {
          Task { await workReport.refreshUsageStatistics() }
          diagnostics.refresh()
        }
      }
      Text("当前记录 Provider 返回的 token；尚未配置价格表，因此不展示可能失真的金额估算。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var storagePage: some View {
    VStack(alignment: .leading, spacing: 18) {
      DaydayCard("本地数据", systemImage: "internaldrive") {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 24) {
            storageMetrics
            Spacer()
            storageActions
          }
          VStack(alignment: .leading, spacing: 14) {
            storageMetrics
            storageActions
          }
        }
        Text("数据保存在本机 Application Support 的 Dayday 目录；此页不上传、清理或改写任何数据。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      DaydayCard("保留策略", systemImage: "clock.arrow.circlepath") {
        LabeledContent("键鼠小时明细", value: "保留 \(InputAggregationPolicy.defaultHourlyRetentionDays) 天")
        LabeledContent("超过保留期", value: "按工作日汇总后移除小时明细")
        Text("其他数据的清理策略尚未提供用户控制，因此不会在这里显示无效的“配置”或“删除”按钮。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      DaydayCard("工作日报导出", systemImage: "square.and.arrow.up") {
        Text("日报 Markdown 导出已在历史页面提供；导出范围以当前历史筛选结果为准。")
          .font(.callout)
          .foregroundStyle(.secondary)
        Button("前往历史导出", systemImage: "clock.arrow.circlepath") {
          openHistory()
        }
      }
    }
    .task { storage.refresh() }
  }

  private var storageMetrics: some View {
    HStack(spacing: 24) {
      MetricView(value: storage.sizeDescription, label: "本地数据占用")
      MetricView(value: "\(storage.snapshot.fileCount)", label: "本地文件")
    }
  }

  private var storageActions: some View {
    HStack(spacing: 10) {
      StatusBadge(
        title: storage.snapshot.isAvailable ? "本地数据可用" : "尚未创建数据目录",
        systemImage: storage.snapshot.isAvailable ? "checkmark.circle.fill" : "circle.dashed",
        color: storage.snapshot.isAvailable ? .green : .secondary
      )
      Button("刷新", systemImage: "arrow.clockwise") { storage.refresh() }
        .disabled(storage.isRefreshing)
      Button("在访达中显示", systemImage: "folder") { storage.revealInFinder() }
        .disabled(!storage.snapshot.isAvailable)
    }
  }

  private var diagnosticsPage: some View {
    VStack(alignment: .leading, spacing: 18) {
      DaydayCard("运行健康", systemImage: "stethoscope") {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 16) {
            diagnosticsSummary
            Spacer()
            diagnosticsRefreshButton
          }
          VStack(alignment: .leading, spacing: 10) {
            diagnosticsSummary
            diagnosticsRefreshButton
          }
        }
        if !diagnostics.failureDescription.isEmpty {
          Label(diagnostics.failureDescription, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
        }
      }

      DaydayCard("最近 24 小时链路", systemImage: "point.3.connected.trianglepath.dotted") {
        LabeledContent("OCR 客观文本", value: diagnostics.objectiveTextDescription)
        LabeledContent("视觉推断", value: diagnostics.visualInferenceDescription)
        LabeledContent("视觉模型调用", value: diagnostics.visionUsageDescription)
        LabeledContent("文本输入聚合", value: diagnostics.textProductionDescription)
        Divider()
        LabeledContent("视觉识别锚点", value: diagnostics.visualAnchorDescription)
        LabeledContent("视觉片段状态", value: diagnostics.visualSegmentDescription)
        LabeledContent("Chrome 桥接心跳", value: diagnostics.chromeDescription)
        LabeledContent("Tabbit 桥接心跳", value: diagnostics.tabbitDescription)
      }

      Text("诊断只显示计数、时间与稳定错误类别，不展示 OCR 正文、视觉总结或网页内容。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .task { diagnostics.refresh() }
  }

  private var diagnosticsSummary: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        StatusBadge(
          title: runtime.collectionStatus.title,
          systemImage: runtime.collectionStatus.symbolName,
          color: runtime.collectionStatus.color
        )
        Text(diagnostics.summaryTitle)
          .font(.headline)
      }
      Text(diagnostics.summaryDetail)
        .font(.callout)
        .foregroundStyle(.secondary)
      if !diagnostics.lastRefreshDescription.isEmpty {
        Text(diagnostics.lastRefreshDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var diagnosticsRefreshButton: some View {
    Button("刷新诊断", systemImage: "arrow.clockwise") {
      diagnostics.refresh()
    }
    .disabled(diagnostics.isRefreshing)
  }
}
