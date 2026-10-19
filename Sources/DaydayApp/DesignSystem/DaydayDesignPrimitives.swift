import SwiftUI

/// A quiet boundary for a genuinely independent task; deliberately not a
/// universal card component.
struct TaskPartition<Content: View>: View {
  let title: String
  let systemImage: String?
  let content: Content

  init(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    DaydayThemeReader { theme, _ in
      VStack(alignment: .leading, spacing: DaydaySpace.m) {
        if let systemImage {
          Label(title, systemImage: systemImage)
            .font(DaydayType.sectionTitle)
            .foregroundStyle(theme[.textPrimary])
        } else {
          Text(title)
            .font(DaydayType.sectionTitle)
            .foregroundStyle(theme[.textPrimary])
        }
        content
      }
      .padding(DaydaySpace.l)
      .background(
        theme[.surfaceRaised],
        in: RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: DaydayRadius.partition, style: .continuous).stroke(
          theme[.separator], lineWidth: DaydayDepth.hairline)
      }
    }
  }
}

enum TemporalState: String, CaseIterable, Identifiable {
  case populated, paused, permission, degraded, failure, emptyLoading
  var id: Self { self }
  var title: String {
    switch self {
    case .populated: "记录中"
    case .paused: "已暂停"
    case .permission: "需要权限"
    case .degraded: "记录受限"
    case .failure: "记录失败"
    case .emptyLoading: "等待首条事实"
    }
  }
  var detail: String {
    switch self {
    case .populated: "最近一条客观事实已进入工作日脉络。"
    case .paused: "暂停期间不新增事实；既有记录保持可见。"
    case .permission: "尚未获得屏幕与辅助功能访问；不会自动请求。"
    case .degraded: "部分来源不可用，时间线会明确保留缺口。"
    case .failure: "记录未能继续；既有事实保持可见，需查看恢复信息。"
    case .emptyLoading: "正在准备本工作日；不会用模拟记录填充空白。"
    }
  }
  var symbol: String {
    switch self {
    case .populated: "record.circle.fill"
    case .paused: "pause.circle.fill"
    case .permission: "lock.trianglebadge.exclamationmark"
    case .degraded: "exclamationmark.triangle"
    case .failure: "xmark.octagon.fill"
    case .emptyLoading: "circle.dashed"
    }
  }
  var role: DaydayThemeRole {
    switch self {
    case .populated: .recording
    case .paused: .warning
    case .permission: .warning
    case .degraded: .warning
    case .failure: .failure
    case .emptyLoading: .evidenceObjective
    }
  }
}

struct TemporalStateNotice: View {
  let state: TemporalState
  var body: some View {
    DaydayThemeReader { theme, _ in
      Label {
        VStack(alignment: .leading, spacing: DaydaySpace.xs) {
          Text(state.title).font(DaydayType.detail.weight(.semibold))
          Text(state.detail).font(DaydayType.detail).foregroundStyle(theme[.textSecondary])
        }
      } icon: {
        Image(systemName: state.symbol).foregroundStyle(theme[state.role])
      }
      .padding(DaydaySpace.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        theme[.surfaceInset],
        in: RoundedRectangle(cornerRadius: DaydayRadius.control, style: .continuous)
      )
      .accessibilityElement(children: .combine)
    }
  }
}
