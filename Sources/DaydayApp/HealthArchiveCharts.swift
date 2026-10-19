import Accessibility
import Charts
import DaydayCore
import SwiftUI

struct HealthMetricCalendarHeatmap: View {
  let presentation: HealthMetricCalendarPresentation
  let tint: Color

  @State private var hoveredDay: HealthMetricCalendarPresentation.Day?

  private var columns: [[HealthMetricCalendarPresentation.Day?]] {
    var calendar = Calendar.autoupdatingCurrent
    calendar.firstWeekday = 2
    guard let first = presentation.days.first else { return [] }
    let leading = (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
    let totalSlots = leading + presentation.days.count
    let weekCount = (totalSlots + 6) / 7
    var slots = [HealthMetricCalendarPresentation.Day?](repeating: nil, count: weekCount * 7)
    for (index, day) in presentation.days.enumerated() { slots[leading + index] = day }
    return stride(from: 0, to: slots.count, by: 7).map {
      Array(slots[$0..<min($0 + 7, slots.count)])
    }
  }

  private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

  var body: some View {
    let calendarColumns = columns
    VStack(alignment: .leading, spacing: DaydaySpace.s) {
      DaydayHeatmapHoverSummary(
        text: hoveredDay.map(hoverText(for:))
          ?? "将指针移到日期上查看具体数值",
        isActive: hoveredDay != nil,
        activeSystemImage: "calendar"
      )

      responsiveCalendar(columns: calendarColumns)

      DaydayHeatmapContinuousLegend(
        title: presentation.kind.healthDisplayName,
        tint: tint,
        minimumLabel: formatMetricValue(
          presentation.minimumValue,
          kind: presentation.kind,
          includesUnit: false
        ),
        maximumLabel: formatMetricValue(
          presentation.maximumValue,
          kind: presentation.kind,
          includesUnit: false
        ),
        unitDetail: "每格一天 · 连续色阶",
        usesMeasuredMetricScale: true
      )
    }
    .onChange(of: presentation) { _, _ in hoveredDay = nil }
  }

  private func responsiveCalendar(
    columns: [[HealthMetricCalendarPresentation.Day?]]
  ) -> some View {
    GeometryReader { proxy in
      let horizontalPadding = DaydaySpace.s * 2
      let weekdayWidth: CGFloat = 18
      let gutter = DaydaySpace.s
      let gridWidth = max(0, proxy.size.width - horizontalPadding - weekdayWidth - gutter)
      let layout = DaydayCalendarHeatmapLayout.fitting(
        availableWidth: gridWidth,
        columnCount: columns.count,
        maximumCellSize: 8.5
      )

      HStack(alignment: .top, spacing: gutter) {
        VStack(spacing: layout.rowSpacing) {
          Color.clear.frame(width: weekdayWidth, height: 12)
          ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
            Text(label)
              .font(DaydayType.micro)
              .foregroundStyle(.secondary)
              .frame(width: weekdayWidth, height: layout.cellSize)
          }
        }

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: layout.columnSpacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { columnIndex, column in
              Text(monthLabel(for: column, at: columnIndex))
                .font(DaydayType.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: layout.cellSize, height: 12, alignment: .leading)
            }
          }

          DaydayHeatmapWaveReveal(
            runID: presentation.kind,
            columnCount: columns.count
          ) { revealProgress, reduceMotion in
            HealthMetricWaveCanvas(
              columns: columns,
              minimumValue: presentation.minimumValue,
              maximumValue: presentation.maximumValue,
              tint: tint,
              layout: layout,
              reduceMotion: reduceMotion,
              revealProgress: revealProgress,
              hoveredDay: $hoveredDay
            )
          }
        }
      }
      .padding(DaydaySpace.s)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: 108)
    .background(
      .primary.opacity(0.028),
      in: RoundedRectangle(cornerRadius: DaydayRadius.control, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(presentation.kind.healthDisplayName)全年热力图")
    .accessibilityValue(
      "最低 \(formatMetricValue(presentation.minimumValue, kind: presentation.kind))，最高 \(formatMetricValue(presentation.maximumValue, kind: presentation.kind))"
    )
    .accessibilityChildren {
      ForEach(presentation.days.filter { $0.value != nil }) { day in
        Text(healthArchiveLongDate(day.date))
          .accessibilityLabel(healthArchiveLongDate(day.date))
          .accessibilityValue(
            day.value.map { formatMetricValue($0, kind: presentation.kind) } ?? "无数据"
          )
      }
    }
  }

  private func monthLabel(
    for column: [HealthMetricCalendarPresentation.Day?],
    at index: Int
  ) -> String {
    let calendar = Calendar.autoupdatingCurrent
    let days = column.compactMap { $0 }
    guard let first = days.first else { return " " }
    if index == 0 { return "\(calendar.component(.month, from: first.date))月" }
    guard let monthStart = days.first(where: { calendar.component(.day, from: $0.date) == 1 })
    else { return " " }
    return "\(calendar.component(.month, from: monthStart.date))月"
  }

  private func hoverText(for day: HealthMetricCalendarPresentation.Day) -> String {
    guard let value = day.value else { return "\(healthArchiveLongDate(day.date)) · 无数据" }
    return
      "\(healthArchiveLongDate(day.date)) · \(formatMetricValue(value, kind: presentation.kind))"
  }
}

struct HealthMetricWaveCanvas: View, @preconcurrency Animatable {
  let columns: [[HealthMetricCalendarPresentation.Day?]]
  let minimumValue: Double
  let maximumValue: Double
  let tint: Color
  let layout: DaydayCalendarHeatmapLayout
  let reduceMotion: Bool
  var revealProgress: Double
  @Binding var hoveredDay: HealthMetricCalendarPresentation.Day?

  var animatableData: Double {
    get { revealProgress }
    set { revealProgress = newValue }
  }

  var body: some View {
    Canvas { context, _ in
      for (columnIndex, column) in columns.enumerated() {
        for (rowIndex, day) in column.enumerated() {
          guard let day else { continue }
          let progress = DaydayHeatmapWaveMotion.cellProgress(
            globalProgress: revealProgress,
            column: columnIndex,
            row: rowIndex,
            columnCount: columns.count,
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
          let origin = CGPoint(
            x: CGFloat(columnIndex) * (layout.cellSize + layout.columnSpacing),
            y: CGFloat(rowIndex) * (layout.cellSize + layout.rowSpacing)
              + CGFloat(verticalOffset) * (layout.cellSize + layout.rowSpacing)
          )
          let baseRect = CGRect(
            origin: origin,
            size: CGSize(width: layout.cellSize, height: layout.cellSize)
          )
          let scaledRect = baseRect.insetBy(
            dx: layout.cellSize * (1 - scale) / 2,
            dy: layout.cellSize * (1 - scale) / 2
          )
          var cellContext = context
          cellContext.opacity = progress
          cellContext.fill(
            Path(roundedRect: scaledRect, cornerRadius: max(1.4, layout.cellSize * 0.22)),
            with: .color(
              DaydayHeatmapScale.color(
                tint: tint,
                value: day.value,
                minimum: minimumValue,
                maximum: maximumValue,
                logarithmic: true
              ))
          )
        }
      }
    }
    .frame(
      width: layout.width,
      height: layout.height + (layout.cellSize + layout.rowSpacing) * 0.45
    )
    .contentShape(Rectangle())
    .onContinuousHover(coordinateSpace: .local) { phase in
      switch phase {
      case .active(let location): updateHover(at: location)
      case .ended: hoveredDay = nil
      }
    }
  }

  private func updateHover(at location: CGPoint) {
    let columnStep = layout.cellSize + layout.columnSpacing
    let rowStep = layout.cellSize + layout.rowSpacing
    guard columnStep > 0, rowStep > 0 else {
      hoveredDay = nil
      return
    }
    let columnIndex = Int(location.x / columnStep)
    let rowIndex = Int(location.y / rowStep)
    guard columns.indices.contains(columnIndex), columns[columnIndex].indices.contains(rowIndex)
    else {
      hoveredDay = nil
      return
    }
    let localX = location.x - CGFloat(columnIndex) * columnStep
    let localY = location.y - CGFloat(rowIndex) * rowStep
    guard localX <= layout.cellSize, localY <= layout.cellSize else {
      hoveredDay = nil
      return
    }
    let next = columns[columnIndex][rowIndex]
    if hoveredDay?.id != next?.id { hoveredDay = next }
  }
}

struct HealthMetricLineChart: View {
  let series: HealthMetricSeries
  let range: HealthMetricTrendRange
  let now: Date
  let tint: Color
  let height: CGFloat
  let showsAxisUnit: Bool
  let displayMode: HealthMetricChartDisplayMode
  let archiveRevision: UInt64
  let exactSampleProvider:
    ((HealthObservationKind, HealthMetricPoint) async -> HealthMetricExactSample?)?
  private let snapshot: HealthMetricLineChartSnapshot

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoveredPoint: HealthMetricPoint?
  @State private var exactSample: HealthMetricExactSample?

  init(
    series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    now: Date,
    tint: Color,
    height: CGFloat = 250,
    showsAxisUnit: Bool = true,
    displayMode: HealthMetricChartDisplayMode = .compact,
    archiveRevision: UInt64 = 0,
    exactSampleProvider:
      ((HealthObservationKind, HealthMetricPoint) async -> HealthMetricExactSample?)? = nil
  ) {
    self.series = series
    self.range = range
    self.now = now
    self.tint = tint
    self.height = height
    self.showsAxisUnit = showsAxisUnit
    self.displayMode = displayMode
    self.archiveRevision = archiveRevision
    self.exactSampleProvider = exactSampleProvider
    let cacheKey = HealthMetricLineChartSnapshotCacheKey.make(
      series: series,
      range: range,
      displayMode: displayMode,
      archiveRevision: archiveRevision,
      now: now
    )
    snapshot = HealthMetricLineChartSnapshotCache.shared.snapshot(for: cacheKey) {
      HealthMetricLineChartSnapshot.make(
        series: series,
        range: range,
        displayMode: displayMode,
        archiveRevision: archiveRevision,
        now: now
      )
    }
  }

  var body: some View {
    Group {
      if snapshot.inspectionPoints.isEmpty {
        ContentUnavailableView(
          "此时间范围暂无数据",
          systemImage: "chart.xyaxis.line"
        )
        .frame(maxWidth: .infinity, minHeight: height)
      } else {
        Chart {
          if let averageValue = snapshot.averageValue {
            RuleMark(
              y: .value("范围平均值", displayValue(averageValue))
            )
            .foregroundStyle(tint.opacity(0.30))
            .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
          }

          if let first = snapshot.inspectionPoints.first,
            let last = snapshot.inspectionPoints.last
          {
            PointMark(
              x: .value("范围开始", first.startedAt),
              y: .value("范围下界", snapshot.axis.domain.lowerBound)
            )
            .opacity(0)
            PointMark(
              x: .value("范围结束", last.startedAt),
              y: .value("范围上界", snapshot.axis.domain.upperBound)
            )
            .opacity(0)
          }

          if let hoveredPoint {
            RuleMark(x: .value("选中时间", hoveredPoint.startedAt))
              .foregroundStyle(.secondary.opacity(0.28))
              .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
            PointMark(
              x: .value("选中时间", hoveredPoint.startedAt),
              y: .value("选中数值", displayValue(hoveredPoint.value))
            )
            .symbolSize(displayMode == .expanded ? 70 : 54)
            .foregroundStyle(tint)
          }
        }
        .chartYScale(domain: snapshot.axis.domain)
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: preferredXAxisMarkCount)) { _ in
            AxisGridLine().foregroundStyle(.secondary.opacity(0.08))
            AxisValueLabel(format: xAxisFormat)
          }
        }
        .chartYAxis {
          AxisMarks(position: .leading, values: snapshot.axis.tickValues) { value in
            AxisGridLine().foregroundStyle(.secondary.opacity(0.09))
            AxisValueLabel {
              if let raw = value.as(Double.self) {
                Text(axisValue(raw))
                  .monospacedDigit()
                  .frame(width: yAxisLabelWidth, alignment: .trailing)
              }
            }
          }
        }
        .chartPlotStyle { plot in
          plot
            .background(.primary.opacity(0.014))
            .overlay(alignment: .topLeading) {
              if showsAxisUnit {
                Text(metricAxisLabel(for: series.kind))
                  .font(.caption2.weight(.medium))
                  .foregroundStyle(.secondary)
                  .padding(.leading, 4)
                  .padding(.top, 3)
                  .allowsHitTesting(false)
              }
            }
        }
        .chartOverlay { proxy in
          GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
              HealthMetricAnimatedLineOverlay(
                points: snapshot.points,
                axis: snapshot.axis,
                kind: series.kind,
                unit: series.unit,
                transitionKey: snapshot.transitionKey,
                tint: tint,
                lineWidth: displayMode == .expanded ? 2.4 : 2,
                reduceMotion: reduceMotion,
                plotFrame: proxy.plotFrame.map { geometry[$0] }
              )
              .allowsHitTesting(false)

              Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                  switch phase {
                  case .active(let location):
                    updateHover(at: location, proxy: proxy, geometry: geometry)
                  case .ended:
                    hoveredPoint = nil
                    exactSample = nil
                  }
                }

              if let hoveredPoint,
                let tooltipPosition = tooltipPosition(
                  for: hoveredPoint,
                  proxy: proxy,
                  geometry: geometry
                )
              {
                HealthMetricChartTooltip(
                  value: formatMetricValue(
                    exactSample?.value ?? hoveredPoint.value,
                    kind: series.kind
                  ),
                  date: hoverDate(for: hoveredPoint, exactSample: exactSample),
                  detail: hoverDetail(for: hoveredPoint, exactSample: exactSample),
                  tint: tint,
                  displayMode: displayMode
                )
                .position(tooltipPosition)
                .allowsHitTesting(false)
              }
            }
            .animation(
              reduceMotion ? nil : .easeOut(duration: 0.10),
              value: hoveredPoint == nil
            )
          }
        }
        .accessibilityChartDescriptor(
          HealthMetricAccessibilityChartDescriptor(
            series: series,
            range: range,
            points: snapshot.inspectionPoints,
            axis: snapshot.axis,
            pointLimit: displayMode.targetSlotCount
          )
        )
        .frame(height: height)
        .accessibilityLabel("\(series.kind.healthDisplayName)\(range.title)趋势图")
        .accessibilityValue(
          hoveredPoint.map { formatMetricValue($0.value, kind: series.kind) }
            ?? snapshot.averageValue.map {
              "共 \(snapshot.inspectionPoints.count) 个数据点，平均 \(formatMetricValue($0, kind: series.kind))"
            } ?? "共 \(snapshot.inspectionPoints.count) 个数据点"
        )
        .onChange(of: range) { _, _ in
          hoveredPoint = nil
          exactSample = nil
        }
        .onChange(of: series.kind) { _, _ in
          hoveredPoint = nil
          exactSample = nil
        }
        .task(id: exactSampleTaskKey) {
          await loadExactSample()
        }
      }
    }
  }

  @MainActor
  private func loadExactSample() async {
    exactSample = nil
    guard let point = hoveredPoint,
      let provider = exactSampleProvider,
      series.aggregation == .discreteAverage,
      point.endedAt.timeIntervalSince(point.startedAt) <= 5 * 60 + 1
    else { return }
    do {
      try await Task.sleep(for: .milliseconds(80))
    } catch {
      return
    }
    guard !Task.isCancelled else { return }
    let loaded = await provider(series.kind, point)
    exactSample = loaded
  }

  private func updateHover(
    at location: CGPoint,
    proxy: ChartProxy,
    geometry: GeometryProxy
  ) {
    guard let plotFrame = proxy.plotFrame else {
      hoveredPoint = nil
      return
    }
    let frame = geometry[plotFrame]
    guard frame.contains(location) else {
      hoveredPoint = nil
      return
    }
    let x = location.x - frame.origin.x
    guard let date: Date = proxy.value(atX: x) else {
      hoveredPoint = nil
      return
    }
    let nextPoint = snapshot.inspectionPoints.min {
      abs($0.startedAt.timeIntervalSince(date)) < abs($1.startedAt.timeIntervalSince(date))
    }
    if nextPoint?.id != hoveredPoint?.id { exactSample = nil }
    hoveredPoint = nextPoint
  }

  private func tooltipPosition(
    for point: HealthMetricPoint,
    proxy: ChartProxy,
    geometry: GeometryProxy
  ) -> CGPoint? {
    guard let plotFrame = proxy.plotFrame,
      let x = proxy.position(forX: point.startedAt),
      let y = proxy.position(forY: displayValue(point.value))
    else { return nil }
    let frame = geometry[plotFrame]
    return HealthMetricChartTooltipLayout.center(
      anchor: CGPoint(x: frame.minX + x, y: frame.minY + y),
      plotFrame: frame,
      containerSize: geometry.size,
      displayMode: displayMode
    )
  }

  private func displayValue(_ value: Double) -> Double {
    healthMetricChartValue(value, kind: series.kind, unit: series.unit)
  }

  private func axisValue(_ value: Double) -> String {
    switch series.unit {
    case .beatsPerMinute, .count, .minutes, .kilocalories, .milliseconds, .decibels:
      value.formatted(.number.precision(.fractionLength(0)))
    default:
      value.formatted(.number.precision(.fractionLength(0...2)))
    }
  }

  private var yAxisLabelWidth: CGFloat {
    let maximumCharacters = snapshot.axis.tickValues.map { axisValue($0).count }.max() ?? 1
    return min(46, max(24, CGFloat(maximumCharacters) * 6.5 + 4))
  }

  private var preferredXAxisMarkCount: Int {
    displayMode == .expanded
      ? max(10, range.preferredXAxisMarkCount) : range.preferredXAxisMarkCount
  }

  private var xAxisFormat: Date.FormatStyle {
    switch range {
    case .yesterday: .dateTime.month().day()
    case .today: .dateTime.hour().minute()
    case .week: .dateTime.weekday(.abbreviated)
    case .month, .quarter: .dateTime.month().day()
    case .year: .dateTime.month(.abbreviated)
    }
  }

  private var exactSampleTaskKey: HealthMetricExactSampleTaskKey? {
    hoveredPoint.map {
      HealthMetricExactSampleTaskKey(kind: series.kind, point: $0, range: range)
    }
  }

  private func hoverDate(
    for point: HealthMetricPoint,
    exactSample: HealthMetricExactSample?
  ) -> String {
    if let exactSample {
      return exactSample.measuredAt.formatted(
        date: range == .week ? .abbreviated : .omitted,
        time: .shortened
      )
    }
    switch range {
    case .today, .yesterday:
      return point.startedAt.formatted(date: .omitted, time: .shortened)
    case .week:
      return point.startedAt.formatted(date: .abbreviated, time: .shortened)
    case .month, .quarter, .year:
      return point.startedAt.formatted(date: .abbreviated, time: .omitted)
    }
  }

  private func hoverDetail(
    for point: HealthMetricPoint,
    exactSample: HealthMetricExactSample?
  ) -> String? {
    if exactSample != nil {
      return "实际测量 · 5 分钟均值 \(formatMetricValue(point.value, kind: series.kind))"
    }
    guard point.contributingSampleCount > 0 else { return nil }
    let duration = point.endedAt.timeIntervalSince(point.startedAt)
    let scope: String
    switch duration {
    case 0...6 * 60: scope = "5 分钟均值"
    case 6 * 60...20 * 60: scope = "15 分钟汇总"
    default: scope = "当日汇总"
    }
    return "\(scope) · \(point.contributingSampleCount) 条事实"
  }
}

private struct HealthMetricExactSampleTaskKey: Hashable {
  let kind: HealthObservationKind
  let point: HealthMetricPoint
  let range: HealthMetricTrendRange
}

enum HealthMetricChartMotion {
  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .timingCurve(0.40, 0, 0.20, 1, duration: 0.32)
  }
}

/// Replaces Swift Charts' mark-derived Audio Graph with a descriptor made only from factual
/// inspection points. The 120/360 interpolated morph slots remain purely visual and can never be
/// announced as HealthKit measurements.
struct HealthMetricAccessibilityChartDescriptor: AXChartDescriptorRepresentable {
  let series: HealthMetricSeries
  let range: HealthMetricTrendRange
  let points: [HealthMetricPoint]
  let axis: HealthMetricChartAxisPresentation
  let pointLimit: Int

  func makeChartDescriptor() -> AXChartDescriptor {
    let factualPoints = HealthMetricPointSampling.downsample(points, limit: max(2, pointLimit))
    let dateValues = factualPoints.map { $0.startedAt.timeIntervalSinceReferenceDate }
    let firstDateValue = dateValues.first ?? 0
    let lastDateValue = max(dateValues.last ?? firstDateValue, firstDateValue + 1)
    let xAxis = AXNumericDataAxisDescriptor(
      title: "时间",
      range: firstDateValue...lastDateValue,
      gridlinePositions: [],
      valueDescriptionProvider: { value in
        Self.dateDescription(
          Date(timeIntervalSinceReferenceDate: value),
          range: range
        )
      }
    )
    let yAxis = AXNumericDataAxisDescriptor(
      title: metricAxisLabel(for: series.kind),
      range: axis.domain,
      gridlinePositions: axis.tickValues,
      valueDescriptionProvider: { value in
        Self.axisValueDescription(value, unit: series.unit, kind: series.kind)
      }
    )
    let segments = Self.factualSegments(
      selectedPoints: factualPoints,
      allPoints: points
    )
    let dataSeries = segments.enumerated().map { index, segment in
      AXDataSeriesDescriptor(
        name: segments.count > 1
          ? "\(series.kind.healthDisplayName)第 \(index + 1) 段"
          : series.kind.healthDisplayName,
        isContinuous: segment.count > 1,
        dataPoints: segment.map { point in
          AXDataPoint(
            x: point.startedAt.timeIntervalSinceReferenceDate,
            y: healthMetricChartValue(point.value, kind: series.kind, unit: series.unit),
            label:
              "\(Self.dateDescription(point.startedAt, range: range))，\(formatMetricValue(point.value, kind: series.kind))"
          )
        }
      )
    }
    return AXChartDescriptor(
      title: "\(series.kind.healthDisplayName)\(range.title)趋势图",
      summary: "基于 \(points.count) 个真实检查点；展示投影不作为健康测量。",
      xAxis: xAxis,
      yAxis: yAxis,
      series: dataSeries
    )
  }

  private static func factualSegments(
    selectedPoints: [HealthMetricPoint],
    allPoints: [HealthMetricPoint]
  ) -> [[HealthMetricPoint]] {
    guard !selectedPoints.isEmpty else { return [] }
    let gapIntervals = HealthMetricGapPolicy.genuineGapIntervals(in: allPoints)
    var segments: [[HealthMetricPoint]] = []
    for point in selectedPoints {
      if let previous = segments.last?.last,
        gapIntervals.contains(where: {
          $0.lowerBound < point.startedAt && $0.upperBound > previous.startedAt
        })
      {
        segments.append([point])
      } else if segments.isEmpty {
        segments.append([point])
      } else {
        segments[segments.count - 1].append(point)
      }
    }
    return segments
  }

  private static func dateDescription(
    _ date: Date,
    range: HealthMetricTrendRange
  ) -> String {
    switch range {
    case .today, .yesterday:
      date.formatted(date: .omitted, time: .shortened)
    case .week:
      date.formatted(date: .abbreviated, time: .shortened)
    case .month, .quarter, .year:
      date.formatted(date: .abbreviated, time: .omitted)
    }
  }

  private static func axisValueDescription(
    _ value: Double,
    unit: HealthMetricUnit,
    kind: HealthObservationKind
  ) -> String {
    let formatted: String
    switch unit {
    case .beatsPerMinute, .count, .minutes, .kilocalories, .milliseconds, .decibels:
      formatted = value.formatted(.number.precision(.fractionLength(0)))
    default:
      formatted = value.formatted(.number.precision(.fractionLength(0...2)))
    }
    return "\(formatted) \(metricAxisLabel(for: kind))"
  }
}

struct HealthMetricChartAxisPresentation: Equatable {
  let domain: ClosedRange<Double>
  let tickValues: [Double]

  static func make(values: [Double], desiredIntervals: Int = 4) -> Self {
    let values = values.filter(\.isFinite)
    guard let minimum = values.min(), let maximum = values.max() else {
      return Self(domain: 0...1, tickValues: [0, 0.5, 1])
    }

    let span = maximum - minimum
    let magnitude = max(abs(minimum), abs(maximum), 1)
    let padding =
      span > 0
      ? max(span * 0.12, magnitude * 0.02)
      : max(magnitude * 0.08, 1)
    let paddedMinimum = minimum - padding
    let paddedMaximum = maximum + padding
    let rawStep = (paddedMaximum - paddedMinimum) / Double(max(2, desiredIntervals))
    let step = niceStep(for: rawStep)
    var lowerBound = floor(paddedMinimum / step) * step
    let upperBound = ceil(paddedMaximum / step) * step
    if minimum >= 0, lowerBound < 0 { lowerBound = 0 }
    let resolvedUpperBound = upperBound > lowerBound ? upperBound : lowerBound + step

    var ticks: [Double] = []
    var value = lowerBound
    while value <= resolvedUpperBound + step * 0.5, ticks.count < 10 {
      ticks.append(abs(value) < step * 0.000_001 ? 0 : value)
      value += step
    }
    return Self(domain: lowerBound...resolvedUpperBound, tickValues: ticks)
  }

  private static func niceStep(for rawStep: Double) -> Double {
    guard rawStep.isFinite, rawStep > 0 else { return 1 }
    let exponent = floor(log10(rawStep))
    let scale = pow(10, exponent)
    let fraction = rawStep / scale
    let niceFraction: Double
    switch fraction {
    case ...1: niceFraction = 1
    case ...2: niceFraction = 2
    case ...2.5: niceFraction = 2.5
    case ...5: niceFraction = 5
    default: niceFraction = 10
    }
    return niceFraction * scale
  }
}

struct HealthMetricLineChartSnapshot: Equatable {
  let points: [HealthMetricMorphPoint]
  let inspectionPoints: [HealthMetricPoint]
  let averageValue: Double?
  let axis: HealthMetricChartAxisPresentation
  let segmentIDsBySlot: [Int: Int]
  let transitionKey: HealthMetricLineChartTransitionKey

  func segmentID(for point: HealthMetricMorphPoint) -> Int {
    segmentIDsBySlot[point.slot] ?? point.slot
  }

  static func make(
    series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    displayMode: HealthMetricChartDisplayMode,
    archiveRevision: UInt64,
    now: Date
  ) -> Self {
    let inspectionPoints = HealthMetricPresentationAdapter.plotPoints(
      from: series,
      range: range,
      now: now
    )
    let points = HealthMetricMorphProjection.make(from: inspectionPoints, mode: displayMode)
    var segmentIDsBySlot: [Int: Int] = [:]
    var activeSegmentID: Int?
    for point in points {
      guard point.date != nil, point.value != nil else {
        activeSegmentID = nil
        continue
      }
      if activeSegmentID == nil || !point.isConnectedToPrevious {
        activeSegmentID = point.slot
      }
      segmentIDsBySlot[point.slot] = activeSegmentID
    }
    var hasher = Hasher()
    for point in inspectionPoints { hasher.combine(point) }
    let values = inspectionPoints.map {
      healthMetricChartValue($0.value, kind: series.kind, unit: series.unit)
    }
    return Self(
      points: points,
      inspectionPoints: inspectionPoints,
      averageValue: HealthMetricPresentationAdapter.averageValue(
        in: inspectionPoints,
        aggregation: series.aggregation
      ),
      axis: HealthMetricChartAxisPresentation.make(
        values: values,
        desiredIntervals: displayMode == .expanded ? 5 : 4
      ),
      segmentIDsBySlot: segmentIDsBySlot,
      transitionKey: .init(
        kind: series.kind,
        range: range,
        displayMode: displayMode,
        archiveRevision: archiveRevision,
        dataFingerprint: hasher.finalize()
      )
    )
  }
}

struct HealthMetricLineChartTransitionKey: Hashable {
  let kind: HealthObservationKind
  let range: HealthMetricTrendRange
  let displayMode: HealthMetricChartDisplayMode
  let archiveRevision: UInt64
  let dataFingerprint: Int
}

struct HealthMetricLineChartSnapshotCacheKey: Hashable {
  let archiveRevision: UInt64
  let kind: HealthObservationKind
  let range: HealthMetricTrendRange
  let displayMode: HealthMetricChartDisplayMode
  let normalizedNow: Date
  let dataFingerprint: Int

  static func make(
    series: HealthMetricSeries,
    range: HealthMetricTrendRange,
    displayMode: HealthMetricChartDisplayMode,
    archiveRevision: UInt64,
    now: Date,
    calendar suppliedCalendar: Calendar = .autoupdatingCurrent
  ) -> Self {
    var hasher = Hasher()
    hasher.combine(series)
    var calendar = suppliedCalendar
    calendar.timeZone = suppliedCalendar.timeZone
    let normalizedNow: Date
    switch range {
    case .today, .week:
      normalizedNow = calendar.dateInterval(of: .minute, for: now)?.start ?? now
    case .yesterday, .month, .quarter, .year:
      normalizedNow = calendar.startOfDay(for: now)
    }
    return Self(
      archiveRevision: archiveRevision,
      kind: series.kind,
      range: range,
      displayMode: displayMode,
      normalizedNow: normalizedNow,
      dataFingerprint: hasher.finalize()
    )
  }
}

@MainActor
final class HealthMetricLineChartSnapshotCache {
  static let shared = HealthMetricLineChartSnapshotCache(capacity: 192)

  let capacity: Int
  private var snapshots: [HealthMetricLineChartSnapshotCacheKey: HealthMetricLineChartSnapshot] =
    [:]
  private var recency: [HealthMetricLineChartSnapshotCacheKey] = []

  init(capacity: Int = 192) {
    self.capacity = max(1, capacity)
  }

  var count: Int { snapshots.count }

  func contains(_ key: HealthMetricLineChartSnapshotCacheKey) -> Bool {
    snapshots[key] != nil
  }

  func snapshot(
    for key: HealthMetricLineChartSnapshotCacheKey,
    make: () -> HealthMetricLineChartSnapshot
  ) -> HealthMetricLineChartSnapshot {
    if let existing = snapshots[key] {
      touch(key)
      return existing
    }
    let snapshot = make()
    snapshots[key] = snapshot
    touch(key)
    while snapshots.count > capacity, let leastRecent = recency.first {
      recency.removeFirst()
      snapshots.removeValue(forKey: leastRecent)
    }
    return snapshot
  }

  func removeAll() {
    snapshots.removeAll(keepingCapacity: true)
    recency.removeAll(keepingCapacity: true)
  }

  private func touch(_ key: HealthMetricLineChartSnapshotCacheKey) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }
}

struct HealthMetricChartTooltipLayout {
  static let size = CGSize(width: 190, height: 68)
  static let expandedSize = CGSize(width: 216, height: 74)
  private static let gap: CGFloat = 10
  private static let margin: CGFloat = 6

  static func size(for displayMode: HealthMetricChartDisplayMode) -> CGSize {
    displayMode == .expanded ? expandedSize : size
  }

  static func center(
    anchor: CGPoint,
    plotFrame: CGRect,
    containerSize: CGSize,
    displayMode: HealthMetricChartDisplayMode = .compact
  ) -> CGPoint {
    let size = size(for: displayMode)
    let horizontalDirection: CGFloat = anchor.x < plotFrame.midX ? 1 : -1
    let verticalDirection: CGFloat =
      anchor.y - plotFrame.minY >= size.height + gap ? -1 : 1
    let proposed = CGPoint(
      x: anchor.x + horizontalDirection * (size.width / 2 + gap),
      y: anchor.y + verticalDirection * (size.height / 2 + gap)
    )
    return CGPoint(
      x: min(
        max(size.width / 2 + margin, proposed.x),
        max(size.width / 2 + margin, containerSize.width - size.width / 2 - margin)
      ),
      y: min(
        max(size.height / 2 + margin, proposed.y),
        max(size.height / 2 + margin, containerSize.height - size.height / 2 - margin)
      )
    )
  }
}

/// Draws every metric with the same fixed-slot cubic path. Swift Charts still owns factual axes,
/// hover and Audio Graph data, while this display-only layer interpolates one stable point catalog
/// so changing ranges cannot fall back to unrelated mark insertion/removal fades.
struct HealthMetricAnimatedLineOverlay: View {
  struct RenderPoint: Equatable {
    let y: Double?
    let connectedToPrevious: Bool
  }

  let points: [HealthMetricMorphPoint]
  let axis: HealthMetricChartAxisPresentation
  let kind: HealthObservationKind
  let unit: HealthMetricUnit
  let transitionKey: HealthMetricLineChartTransitionKey
  let tint: Color
  let lineWidth: CGFloat
  let reduceMotion: Bool
  let plotFrame: CGRect?

  @State private var source: [RenderPoint]
  @State private var target: [RenderPoint]
  @State private var progress = 1.0

  init(
    points: [HealthMetricMorphPoint],
    axis: HealthMetricChartAxisPresentation,
    kind: HealthObservationKind,
    unit: HealthMetricUnit,
    transitionKey: HealthMetricLineChartTransitionKey,
    tint: Color,
    lineWidth: CGFloat,
    reduceMotion: Bool,
    plotFrame: CGRect?
  ) {
    self.points = points
    self.axis = axis
    self.kind = kind
    self.unit = unit
    self.transitionKey = transitionKey
    self.tint = tint
    self.lineWidth = lineWidth
    self.reduceMotion = reduceMotion
    self.plotFrame = plotFrame
    let initial = Self.normalized(points, axis: axis, kind: kind, unit: unit)
    _source = State(initialValue: initial)
    _target = State(initialValue: initial)
  }

  var body: some View {
    HealthMetricMorphCanvas(
      source: source,
      target: target,
      progress: progress,
      tint: tint,
      lineWidth: lineWidth,
      plotFrame: plotFrame
    )
    .task(id: transitionKey) { await transition() }
    .onChange(of: reduceMotion) { _, _ in
      Task { await transition() }
    }
  }

  private var interpolatedPoints: [RenderPoint] {
    guard source.count == target.count else { return target }
    return zip(source, target).map { old, new in
      let y: Double?
      switch (old.y, new.y) {
      case (.some(let oldY), .some(let newY)):
        y = oldY + (newY - oldY) * progress
      case (.some(let oldY), .none):
        y = progress < 1 ? oldY : nil
      case (.none, .some(let newY)):
        y = progress > 0 ? newY : nil
      case (.none, .none):
        y = nil
      }
      return RenderPoint(
        y: y,
        connectedToPrevious: progress < 0.5
          ? old.connectedToPrevious : new.connectedToPrevious
      )
    }
  }

  @MainActor
  private func transition() async {
    let current = interpolatedPoints
    let next = Self.normalized(points, axis: axis, kind: kind, unit: unit)
    guard current != next else { return }
    source = current
    target = next
    progress = 0
    guard !reduceMotion else {
      progress = 1
      return
    }
    // Commit the zero-progress frame before starting the animation. Without this frame boundary,
    // SwiftUI can coalesce both assignments and render only the destination curve.
    do {
      try await Task.sleep(for: .milliseconds(12))
    } catch {
      return
    }
    guard !Task.isCancelled else { return }
    withAnimation(HealthMetricChartMotion.animation(reduceMotion: false)) {
      progress = 1
    }
  }

  private static func normalized(
    _ points: [HealthMetricMorphPoint],
    axis: HealthMetricChartAxisPresentation,
    kind: HealthObservationKind,
    unit: HealthMetricUnit
  ) -> [RenderPoint] {
    let span = max(.leastNonzeroMagnitude, axis.domain.upperBound - axis.domain.lowerBound)
    return points.map { point in
      RenderPoint(
        y: point.value.map {
          let displayed = healthMetricChartValue($0, kind: kind, unit: unit)
          return min(1, max(0, (displayed - axis.domain.lowerBound) / span))
        },
        connectedToPrevious: point.isConnectedToPrevious
      )
    }
  }

}

/// Makes the scalar morph progress part of SwiftUI's animatable data. A Canvas closure alone does
/// not interpolate arbitrary state values, which previously allowed range changes to jump straight
/// to the destination even though they were wrapped in `withAnimation`.
struct HealthMetricMorphCanvas: View, @preconcurrency Animatable {
  typealias RenderPoint = HealthMetricAnimatedLineOverlay.RenderPoint

  let source: [RenderPoint]
  let target: [RenderPoint]
  var progress: Double
  let tint: Color
  let lineWidth: CGFloat
  let plotFrame: CGRect?

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    Canvas { context, _ in
      guard let plotFrame, plotFrame.width > 0, plotFrame.height > 0 else { return }
      for segment in segments(from: interpolatedPoints, frame: plotFrame)
      where segment.count > 1 {
        let line = smoothPath(for: segment)
        var area = line
        if let first = segment.first, let last = segment.last {
          area.addLine(to: CGPoint(x: last.x, y: plotFrame.maxY))
          area.addLine(to: CGPoint(x: first.x, y: plotFrame.maxY))
          area.closeSubpath()
          context.fill(area, with: .color(tint.opacity(0.07)))
        }
        context.stroke(
          line,
          with: .color(tint),
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round
          )
        )
      }
    }
  }

  var interpolatedPoints: [RenderPoint] {
    guard source.count == target.count else { return target }
    return zip(source, target).map { old, new in
      let y: Double?
      switch (old.y, new.y) {
      case (.some(let oldY), .some(let newY)):
        y = oldY + (newY - oldY) * progress
      case (.some(let oldY), .none):
        y = progress < 1 ? oldY : nil
      case (.none, .some(let newY)):
        y = progress > 0 ? newY : nil
      case (.none, .none):
        y = nil
      }
      return RenderPoint(
        y: y,
        connectedToPrevious: progress < 0.5
          ? old.connectedToPrevious : new.connectedToPrevious
      )
    }
  }

  private func segments(from points: [RenderPoint], frame: CGRect) -> [[CGPoint]] {
    guard points.count > 1 else { return [] }
    var result: [[CGPoint]] = []
    var active: [CGPoint] = []
    for (index, point) in points.enumerated() {
      guard let y = point.y else {
        if !active.isEmpty { result.append(active) }
        active = []
        continue
      }
      if !point.connectedToPrevious, !active.isEmpty {
        result.append(active)
        active = []
      }
      active.append(
        CGPoint(
          x: frame.minX + frame.width * CGFloat(index) / CGFloat(points.count - 1),
          y: frame.maxY - frame.height * CGFloat(y)
        )
      )
    }
    if !active.isEmpty { result.append(active) }
    return result
  }

  private func smoothPath(for points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    for (left, right) in zip(points, points.dropFirst()) {
      let middleX = (left.x + right.x) / 2
      path.addCurve(
        to: right,
        control1: CGPoint(x: middleX, y: left.y),
        control2: CGPoint(x: middleX, y: right.y)
      )
    }
    return path
  }
}

private struct HealthMetricChartTooltip: View {
  let value: String
  let date: String
  let detail: String?
  let tint: Color
  let displayMode: HealthMetricChartDisplayMode

  private var size: CGSize {
    HealthMetricChartTooltipLayout.size(for: displayMode)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(
          displayMode == .expanded
            ? DaydayType.sectionTitle.weight(.semibold)
            : DaydayType.detail.weight(.semibold)
        )
        .monospacedDigit()
        .foregroundStyle(.primary)
      Text(date)
        .font(DaydayType.micro)
        .foregroundStyle(.secondary)
      if let detail {
        Text(detail)
          .font(DaydayType.micro)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 10)
    .frame(
      width: size.width,
      height: size.height,
      alignment: .leading
    )
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(tint.opacity(0.24), lineWidth: DaydayDepth.hairline)
    }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    .accessibilityElement(children: .combine)
  }
}

struct HealthArchiveCoverageBarChart: View {
  let coverage: [HealthObservationCoverage]

  private var sortedCoverage: [HealthObservationCoverage] {
    coverage.sorted {
      if $0.observationCount != $1.observationCount {
        return $0.observationCount > $1.observationCount
      }
      return $0.kind.rawValue < $1.kind.rawValue
    }
  }

  private var leadingCoverage: [HealthObservationCoverage] {
    Array(sortedCoverage.prefix(12).reversed())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DaydaySpace.m) {
      VStack(alignment: .leading, spacing: DaydaySpace.xs) {
        Text("记录最多的 12 类")
          .font(DaydayType.sectionTitle)
        Text("条形长度表示入档记录数量，不表示健康水平。")
          .font(DaydayType.metadata)
          .foregroundStyle(.secondary)
      }

      Chart(leadingCoverage) { item in
        BarMark(
          x: .value("记录数", item.observationCount),
          y: .value("类型", item.kind.healthDisplayName)
        )
        .foregroundStyle(item.kind.healthTint)
        .cornerRadius(4)
        .annotation(position: .trailing, alignment: .leading) {
          Text(item.observationCount.formatted())
            .font(DaydayType.micro)
            .foregroundStyle(.secondary)
        }
      }
      .chartXAxis {
        AxisMarks(position: .bottom) { _ in
          AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
          AxisValueLabel()
        }
      }
      .chartYAxis { AxisMarks(position: .leading) }
      .frame(minHeight: 330)
      .accessibilityHidden(true)

      HealthArchiveCoverageDataDisclosure(coverage: sortedCoverage)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct HealthArchiveDayDataDisclosure: View {
  let title: String
  let days: [HealthArchiveDensityPresentation.Day]

  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(title, isExpanded: $isExpanded) {
      LazyVStack(spacing: 0) {
        ForEach(days) { day in
          HStack {
            Text(healthArchiveLongDate(day.date))
            Spacer()
            Text("\(day.observationCount.formatted()) 条")
              .monospacedDigit()
          }
          .font(DaydayType.detail)
          .padding(.vertical, DaydaySpace.s)
          .accessibilityElement(children: .combine)
          if day.id != days.last?.id { Divider() }
        }
      }
      .padding(.top, DaydaySpace.s)
    }
    .font(DaydayType.detail)
  }
}

private func healthArchiveLongDate(_ date: Date) -> String {
  let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
  guard let year = components.year, let month = components.month, let day = components.day else {
    return date.formatted(date: .numeric, time: .omitted)
  }
  return "\(year)年\(month)月\(day)日"
}

private struct HealthArchiveCoverageDataDisclosure: View {
  let coverage: [HealthObservationCoverage]

  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup("查看全部 \(coverage.count) 种类型", isExpanded: $isExpanded) {
      LazyVStack(spacing: 0) {
        ForEach(coverage) { item in
          HStack(spacing: DaydaySpace.s) {
            Circle()
              .fill(item.kind.healthTint)
              .frame(width: 8, height: 8)
              .accessibilityHidden(true)
            Text(item.kind.healthDisplayName)
            Text(item.kind.healthGroup.title)
              .font(DaydayType.metadata)
              .foregroundStyle(.secondary)
            Spacer()
            Text("\(item.observationCount.formatted()) 条")
              .monospacedDigit()
          }
          .font(DaydayType.detail)
          .padding(.vertical, DaydaySpace.s)
          .accessibilityElement(children: .combine)
          if item.id != coverage.last?.id { Divider() }
        }
      }
      .padding(.top, DaydaySpace.s)
    }
    .font(DaydayType.detail)
  }
}

extension HealthArchiveKindGroup {
  fileprivate var tint: Color {
    switch self {
    case .heart: .pink
    case .activity: .green
    case .sleepAndMindfulness: .indigo
    case .body: .blue
    case .nutrition: .orange
    case .environment: .teal
    }
  }
}

extension HealthObservationKind {
  var healthTint: Color { healthGroup.tint }

  var healthDisplayName: String {
    switch self {
    case .heartRate: "心率"
    case .restingHeartRate: "静息心率"
    case .heartRateVariabilitySDNN: "心率变异性"
    case .respiratoryRate: "呼吸频率"
    case .oxygenSaturation: "血氧饱和度"
    case .walkingHeartRateAverage: "步行平均心率"
    case .vo2Max: "心肺适能"
    case .sleepingWristTemperature: "睡眠腕温变化"
    case .stepCount: "步数"
    case .distanceWalkingRunning: "步行与跑步距离"
    case .distanceCycling: "骑行距离"
    case .flightsClimbed: "爬楼层数"
    case .activeEnergyBurned: "活动能量"
    case .basalEnergyBurned: "静息能量"
    case .appleExerciseTime: "锻炼时间"
    case .appleStandTime: "站立时间"
    case .appleMoveTime: "活动时间"
    case .timeInDaylight: "日照时间"
    case .workout: "训练"
    case .bodyMass: "体重"
    case .bodyMassIndex: "BMI"
    case .height: "身高"
    case .bodyFatPercentage: "体脂率"
    case .leanBodyMass: "去脂体重"
    case .sleepAnalysis: "睡眠分析"
    case .mindfulSession: "正念时段"
    case .appleStandHour: "站立小时"
    case .walkingSpeed: "步行速度"
    case .walkingStepLength: "步幅"
    case .walkingAsymmetryPercentage: "步态不对称性"
    case .walkingDoubleSupportPercentage: "双支撑时间"
    case .appleWalkingSteadiness: "步行稳定性"
    case .stairAscentSpeed: "上楼速度"
    case .stairDescentSpeed: "下楼速度"
    case .sixMinuteWalkTestDistance: "六分钟步行距离"
    case .runningSpeed: "跑步速度"
    case .runningPower: "跑步功率"
    case .runningStrideLength: "跑步步幅"
    case .runningGroundContactTime: "触地时间"
    case .runningVerticalOscillation: "垂直振幅"
    case .dietaryWater: "饮水"
    case .dietaryEnergyConsumed: "膳食能量"
    case .dietaryProtein: "膳食蛋白质"
    case .dietaryCarbohydrates: "膳食碳水"
    case .dietaryFatTotal: "膳食脂肪"
    case .dietarySugar: "膳食糖"
    case .dietaryFiber: "膳食纤维"
    case .dietarySodium: "膳食钠"
    case .dietaryCaffeine: "膳食咖啡因"
    case .headphoneAudioExposure: "耳机音量暴露"
    case .environmentalAudioExposure: "环境音量暴露"
    }
  }

  var healthSymbolName: String {
    switch self {
    case .heartRate, .restingHeartRate, .walkingHeartRateAverage: "heart.fill"
    case .heartRateVariabilitySDNN: "waveform.path.ecg"
    case .respiratoryRate: "lungs.fill"
    case .oxygenSaturation: "drop.fill"
    case .vo2Max: "figure.run"
    case .sleepingWristTemperature: "thermometer.medium"
    case .stepCount: "figure.walk"
    case .distanceWalkingRunning, .walkingSpeed: "figure.walk.motion"
    case .distanceCycling: "bicycle"
    case .activeEnergyBurned, .basalEnergyBurned: "flame.fill"
    case .appleExerciseTime, .workout: "figure.run.circle.fill"
    case .timeInDaylight: "sun.max.fill"
    case .sleepAnalysis: "bed.double.fill"
    case .mindfulSession: "brain.head.profile"
    case .bodyMass: "scalemass.fill"
    case .bodyMassIndex: "figure.arms.open"
    case .dietaryWater: "waterbottle.fill"
    case .headphoneAudioExposure: "headphones"
    case .environmentalAudioExposure: "ear.fill"
    default: "waveform.path.ecg"
    }
  }
}

func metricAxisLabel(for kind: HealthObservationKind) -> String {
  switch kind {
  case .heartRate, .restingHeartRate, .walkingHeartRateAverage: "BPM"
  case .heartRateVariabilitySDNN: "毫秒"
  case .respiratoryRate: "次/分"
  case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage,
    .walkingDoubleSupportPercentage:
    "%"
  case .vo2Max: "mL/kg·min"
  case .sleepingWristTemperature: "℃"
  case .stepCount: "步"
  case .flightsClimbed: "层"
  case .distanceWalkingRunning, .distanceCycling: "公里"
  case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed: "千卡"
  case .appleExerciseTime, .appleStandTime, .appleMoveTime, .timeInDaylight: "分钟"
  case .sleepAnalysis, .mindfulSession, .workout: "小时"
  case .bodyMass, .leanBodyMass: "公斤"
  case .height, .sixMinuteWalkTestDistance: "米"
  case .walkingStepLength, .runningStrideLength, .runningVerticalOscillation: "厘米"
  case .bodyMassIndex: "BMI"
  case .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed, .runningSpeed: "米/秒"
  case .runningPower: "瓦"
  case .runningGroundContactTime: "毫秒"
  case .appleStandHour: "小时"
  case .dietaryWater: "升"
  case .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietarySugar,
    .dietaryFiber:
    "克"
  case .dietarySodium, .dietaryCaffeine: "毫克"
  case .headphoneAudioExposure, .environmentalAudioExposure: "dB(A)"
  default: "数值"
  }
}

func healthMetricChartValue(
  _ value: Double,
  kind: HealthObservationKind,
  unit: HealthMetricUnit
) -> Double {
  switch unit {
  case .seconds:
    value / 3_600
  case .percentage:
    value * 100
  case .kilograms
  where kind == .dietaryProtein || kind == .dietaryCarbohydrates
    || kind == .dietaryFatTotal || kind == .dietarySugar || kind == .dietaryFiber:
    value * 1_000
  case .meters where kind == .distanceWalkingRunning || kind == .distanceCycling:
    value / 1_000
  case .meters
  where kind == .walkingStepLength || kind == .runningStrideLength
    || kind == .runningVerticalOscillation:
    value * 100
  default:
    value
  }
}

func formatMetricValue(
  _ value: Double,
  kind: HealthObservationKind,
  includesUnit: Bool = true
) -> String {
  switch kind {
  case .heartRate, .restingHeartRate, .walkingHeartRateAverage:
    let number = value.formatted(.number.precision(.fractionLength(0)))
    return includesUnit ? "\(number) BPM" : number
  case .heartRateVariabilitySDNN:
    let number = value.formatted(.number.precision(.fractionLength(0)))
    return includesUnit ? "\(number) 毫秒" : number
  case .respiratoryRate:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 次/分" : number
  case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage,
    .walkingDoubleSupportPercentage:
    let number = (value * 100).formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number)%" : number
  case .vo2Max:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) mL/kg·min" : number
  case .sleepingWristTemperature:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number)℃" : number
  case .stepCount:
    let number = value.formatted(.number.precision(.fractionLength(0)))
    return includesUnit ? "\(number) 步" : number
  case .flightsClimbed:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 层" : number
  case .distanceWalkingRunning, .distanceCycling:
    let number = (value / 1_000).formatted(.number.precision(.fractionLength(0...2)))
    return includesUnit ? "\(number) 公里" : number
  case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed:
    let number = value.formatted(.number.precision(.fractionLength(0)))
    return includesUnit ? "\(number) 千卡" : number
  case .appleExerciseTime, .appleStandTime, .appleMoveTime, .timeInDaylight:
    let number = value.formatted(.number.precision(.fractionLength(0)))
    return includesUnit ? "\(number) 分钟" : number
  case .sleepAnalysis, .mindfulSession, .workout:
    let totalMinutes = max(0, Int((value / 60).rounded()))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    let number: String
    if hours == 0 {
      number = "\(minutes) 分钟"
    } else {
      number = minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
    }
    return includesUnit
      ? number : (value / 3_600).formatted(.number.precision(.fractionLength(0...1)))
  case .bodyMass, .leanBodyMass:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 公斤" : number
  case .bodyMassIndex:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "BMI \(number)" : number
  case .height, .sixMinuteWalkTestDistance:
    let number = value.formatted(.number.precision(.fractionLength(0...2)))
    return includesUnit ? "\(number) 米" : number
  case .walkingStepLength, .runningStrideLength, .runningVerticalOscillation:
    let number = (value * 100).formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 厘米" : number
  case .walkingSpeed, .stairAscentSpeed, .stairDescentSpeed, .runningSpeed:
    let number = value.formatted(.number.precision(.fractionLength(0...2)))
    return includesUnit ? "\(number) 米/秒" : number
  case .appleWalkingSteadiness:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number)" : number
  case .runningPower:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 瓦" : number
  case .runningGroundContactTime:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 毫秒" : number
  case .appleStandHour:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 小时" : number
  case .dietaryWater:
    let number = value.formatted(.number.precision(.fractionLength(0...2)))
    return includesUnit ? "\(number) 升" : number
  case .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal, .dietarySugar,
    .dietaryFiber:
    let number = (value * 1_000).formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 克" : number
  case .dietarySodium, .dietaryCaffeine:
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return includesUnit ? "\(number) 毫克" : number
  case .headphoneAudioExposure, .environmentalAudioExposure:
    let number = value.formatted(.number.precision(.fractionLength(0)))
    return includesUnit ? "\(number) dB(A)" : number
  }
}
