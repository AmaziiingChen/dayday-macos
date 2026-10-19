import DaydayCore
import SwiftUI

enum MenuBarApplicationBarLayout {
  static let durationColumnWidth: CGFloat = 72
  static let minimumVisibleBarWidth: CGFloat = 3

  static func normalizedFraction(duration: TimeInterval, maximum: TimeInterval) -> CGFloat {
    guard duration.isFinite, maximum.isFinite, duration > 0, maximum > 0 else { return 0 }
    return CGFloat(min(1, duration / maximum))
  }
}

struct MenuBarKeyMouseHeatmaps: View {
  let input: MenuBarInputSummaryPresentation
  let state: MenuBarInsightsPresentation.State

  var body: some View {
    switch state {
    case .loading:
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 112)
    case .failure:
      Label("暂时无法读取本机聚合统计", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .empty:
      Label("范围内暂无键鼠聚合", systemImage: "keyboard")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .populated:
      VStack(spacing: 8) {
        HStack(spacing: 10) {
          MenuBarKeyboardHeatmap(counts: input.keyboardCounts)
            .frame(maxWidth: .infinity, minHeight: 84)
          Divider().frame(height: 88)
          MenuBarPointerHeatmap(display: input.pointerDisplay?.display)
            .frame(maxWidth: .infinity, minHeight: 84)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "键鼠热图。键位按下 \(input.keyPressCount) 次，点击 \(input.clickCount) 次，滚动动作 \(input.scrollActionCount) 次。")
        MenuBarInputSummaryStrip(input: input)
      }
    }
  }
}

struct MenuBarApplicationMiniView: View {
  let applications: [ApplicationUsagePresentation.Summary]
  let switchCount: Int
  let hasIncompleteFacts: Bool
  let state: MenuBarInsightsPresentation.State

  var body: some View {
    switch state {
    case .loading:
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 112)
    case .failure:
      Label("暂时无法读取本机应用时长", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .empty:
      Label("范围内暂无连续前台应用事实", systemImage: "macwindow")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .populated:
      applicationBars
    }
  }

  private var applicationBars: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let maximum = applications.map(\.duration).max(), maximum > 0 {
        ForEach(applications) { application in
          HStack(spacing: 7) {
            Text(application.displayLabel)
              .font(.caption.weight(.medium))
              .lineLimit(1)
              .frame(width: 94, alignment: .leading)
            MenuBarApplicationDurationBar(
              fraction: MenuBarApplicationBarLayout.normalizedFraction(
                duration: application.duration,
                maximum: maximum
              )
            )
            .frame(height: 6)
            Text(application.duration.durationText)
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .minimumScaleFactor(0.85)
              .frame(
                width: MenuBarApplicationBarLayout.durationColumnWidth,
                alignment: .trailing
              )
          }
        }
        HStack(spacing: 10) {
          Label("\(switchCount) 次切换", systemImage: "arrow.left.arrow.right")
          if hasIncompleteFacts {
            Label("前台事实不完整", systemImage: "exclamationmark.circle")
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      } else {
        Label("范围内暂无连续前台应用事实", systemImage: "macwindow")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MenuBarApplicationDurationBar: View {
  let fraction: CGFloat

  var body: some View {
    DaydayGrowingBar(
      fraction: fraction,
      axis: .horizontal,
      minimumVisibleLength: MenuBarApplicationBarLayout.minimumVisibleBarWidth
    ) {
      Capsule()
        .fill(Color.accentColor.opacity(0.82))
    }
  }
}

private struct MenuBarKeyboardHeatmap: View {
  private struct Key {
    let code: UInt16
    let width: CGFloat
  }

  let counts: [UInt16: UInt64]

  private static let rows: [[Key]] = [
    [
      .init(code: 53, width: 1.1), .init(code: 122, width: 1), .init(code: 120, width: 1),
      .init(code: 99, width: 1), .init(code: 118, width: 1), .init(code: 96, width: 1),
      .init(code: 97, width: 1), .init(code: 98, width: 1), .init(code: 100, width: 1),
      .init(code: 101, width: 1), .init(code: 109, width: 1), .init(code: 103, width: 1),
      .init(code: 111, width: 1),
    ],
    [
      .init(code: 50, width: 1), .init(code: 18, width: 1), .init(code: 19, width: 1),
      .init(code: 20, width: 1), .init(code: 21, width: 1), .init(code: 23, width: 1),
      .init(code: 22, width: 1), .init(code: 26, width: 1), .init(code: 28, width: 1),
      .init(code: 25, width: 1), .init(code: 29, width: 1), .init(code: 27, width: 1),
      .init(code: 24, width: 1), .init(code: 51, width: 1.55),
    ],
    [
      .init(code: 48, width: 1.5), .init(code: 12, width: 1), .init(code: 13, width: 1),
      .init(code: 14, width: 1), .init(code: 15, width: 1), .init(code: 17, width: 1),
      .init(code: 16, width: 1), .init(code: 32, width: 1), .init(code: 34, width: 1),
      .init(code: 31, width: 1), .init(code: 35, width: 1), .init(code: 33, width: 1),
      .init(code: 30, width: 1), .init(code: 42, width: 1),
    ],
    [
      .init(code: 57, width: 1.75), .init(code: 0, width: 1), .init(code: 1, width: 1),
      .init(code: 2, width: 1), .init(code: 3, width: 1), .init(code: 5, width: 1),
      .init(code: 4, width: 1), .init(code: 38, width: 1), .init(code: 40, width: 1),
      .init(code: 37, width: 1), .init(code: 41, width: 1), .init(code: 39, width: 1),
      .init(code: 36, width: 1.85),
    ],
    [
      .init(code: 56, width: 2.2), .init(code: 6, width: 1), .init(code: 7, width: 1),
      .init(code: 8, width: 1), .init(code: 9, width: 1), .init(code: 11, width: 1),
      .init(code: 45, width: 1), .init(code: 46, width: 1), .init(code: 43, width: 1),
      .init(code: 47, width: 1), .init(code: 44, width: 1), .init(code: 60, width: 2.2),
    ],
    [
      .init(code: 63, width: 1.1), .init(code: 59, width: 1.15), .init(code: 58, width: 1.15),
      .init(code: 55, width: 1.3), .init(code: 49, width: 5.35), .init(code: 54, width: 1.3),
      .init(code: 61, width: 1.15), .init(code: 123, width: 1), .init(code: 126, width: 1),
      .init(code: 125, width: 1), .init(code: 124, width: 1),
    ],
  ]

  var body: some View {
    let maximum = counts.values.max() ?? 1
    DaydayHeatmapWaveReveal(
      runID: "menu-keyboard",
      columnCount: Self.rows.map(\.count).max() ?? 1
    ) { revealProgress, reduceMotion in
      WaveCanvas(
        rows: Self.rows,
        counts: counts,
        maximum: maximum,
        reduceMotion: reduceMotion,
        revealProgress: revealProgress
      )
      .padding(5)
      .background(
        Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .accessibilityHidden(true)
    }
  }

  private struct WaveCanvas: View, @preconcurrency Animatable {
    let rows: [[Key]]
    let counts: [UInt16: UInt64]
    let maximum: UInt64
    let reduceMotion: Bool
    var revealProgress: Double

    var animatableData: Double {
      get { revealProgress }
      set { revealProgress = newValue }
    }

    var body: some View {
      Canvas { context, size in
        let rowGap: CGFloat = 2
        let keyGap: CGFloat = 1.5
        let rowHeight =
          (size.height - rowGap * CGFloat(rows.count - 1)) / CGFloat(rows.count)
        let columnCount = rows.map(\.count).max() ?? 1
        for (rowIndex, row) in rows.enumerated() {
          let availableWidth = size.width - keyGap * CGFloat(row.count - 1)
          let units = row.reduce(CGFloat.zero) { $0 + $1.width }
          var x: CGFloat = 0
          for (columnIndex, key) in row.enumerated() {
            let width = availableWidth * key.width / units
            let progress = DaydayHeatmapWaveMotion.cellProgress(
              globalProgress: revealProgress,
              column: columnIndex,
              row: rowIndex,
              columnCount: columnCount,
              reduceMotion: reduceMotion
            )
            let scale = DaydayHeatmapWaveMotion.cellScale(
              revealProgress: progress,
              reduceMotion: reduceMotion
            )
            let verticalOffset = DaydayHeatmapWaveMotion.cellVerticalOffset(
              revealProgress: progress,
              reduceMotion: reduceMotion
            )
            let baseRect = CGRect(
              x: x,
              y: CGFloat(rowIndex) * (rowHeight + rowGap)
                + CGFloat(verticalOffset) * (rowHeight + rowGap),
              width: width,
              height: rowHeight
            ).insetBy(dx: 0.2, dy: 0.2)
            let rect = baseRect.insetBy(
              dx: baseRect.width * (1 - scale) / 2,
              dy: baseRect.height * (1 - scale) / 2
            )
            var cellContext = context
            cellContext.opacity = progress
            cellContext.fill(
              Path(rect),
              with: .color(heatColor(value: counts[key.code, default: 0], maximum: maximum)))
            x += width + keyGap
          }
        }
      }
    }
  }
}

private struct MenuBarPointerHeatmap: View {
  let display: DisplayInputAggregate?

  var body: some View {
    DaydayHeatmapWaveReveal(
      runID: "menu-pointer",
      columnCount: max(1, Int(display?.grid.columns ?? 1))
    ) { revealProgress, reduceMotion in
      WaveCanvas(
        display: display,
        reduceMotion: reduceMotion,
        revealProgress: revealProgress
      )
      .padding(5)
      .background(
        Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .accessibilityHidden(true)
    }
  }

  private struct WaveCanvas: View, @preconcurrency Animatable {
    let display: DisplayInputAggregate?
    let reduceMotion: Bool
    var revealProgress: Double

    var animatableData: Double {
      get { revealProgress }
      set { revealProgress = newValue }
    }

    var body: some View {
      Canvas { context, size in
        guard let display else {
          context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.secondary.opacity(0.08)))
          return
        }
        let columns = Int(display.grid.columns)
        let rows = Int(display.grid.rows)
        guard columns > 0, rows > 0 else { return }
        let values = Dictionary(
          uniqueKeysWithValues: display.grid.cells.map { cell in
            (Int(cell.row) * columns + Int(cell.column), clickCount(for: cell))
          })
        let maximum = values.values.max() ?? 1
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        for row in 0..<rows {
          for column in 0..<columns {
            let progress = DaydayHeatmapWaveMotion.cellProgress(
              globalProgress: revealProgress,
              column: column,
              row: row,
              columnCount: columns,
              reduceMotion: reduceMotion
            )
            let scale = DaydayHeatmapWaveMotion.cellScale(
              revealProgress: progress,
              reduceMotion: reduceMotion
            )
            let verticalOffset = DaydayHeatmapWaveMotion.cellVerticalOffset(
              revealProgress: progress,
              reduceMotion: reduceMotion
            )
            let baseRect = CGRect(
              x: CGFloat(column) * cellWidth,
              y: CGFloat(row) * cellHeight + CGFloat(verticalOffset) * cellHeight,
              width: cellWidth,
              height: cellHeight
            ).insetBy(dx: 0.35, dy: 0.35)
            let rect = baseRect.insetBy(
              dx: baseRect.width * (1 - scale) / 2,
              dy: baseRect.height * (1 - scale) / 2
            )
            var cellContext = context
            cellContext.opacity = progress
            cellContext.fill(
              Path(rect),
              with: .color(
                heatColor(value: values[row * columns + column] ?? 0, maximum: maximum)))
          }
        }
      }
    }

    private func clickCount(for cell: NormalizedGridCell) -> UInt64 {
      [cell.clicks.left, cell.clicks.right, cell.clicks.other].reduce(0) { partial, count in
        let sum = partial.addingReportingOverflow(count)
        return sum.overflow ? UInt64.max : sum.partialValue
      }
    }
  }
}

private struct MenuBarInputSummaryStrip: View {
  let input: MenuBarInputSummaryPresentation

  var body: some View {
    HStack(spacing: 0) {
      MenuBarMiniMetric(label: "键位按下", value: "\(input.keyPressCount)", symbol: "keyboard")
      Divider().frame(height: 20)
      MenuBarMiniMetric(label: "点击", value: "\(input.clickCount)", symbol: "cursorarrow.click")
      Divider().frame(height: 20)
      MenuBarMiniMetric(label: "滚动动作", value: "\(input.scrollActionCount)", symbol: "scroll")
    }
    .padding(.vertical, 5)
    .background(
      .quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct MenuBarMiniMetric: View {
  let label: String
  let value: String
  let symbol: String

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).font(.caption2)
      Text(label)
      Text(value)
        .font(.caption.monospacedDigit().weight(.semibold))
        .daydayLiveMetricValue(value)
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity)
  }
}

private func heatColor(value: UInt64, maximum: UInt64) -> Color {
  DaydayHeatmapScale.color(
    tint: .accentColor,
    value: Double(value),
    maximum: Double(maximum)
  )
}
