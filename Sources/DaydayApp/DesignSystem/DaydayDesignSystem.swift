import SwiftUI

/// Semantic roles are intentionally independent: a later theme may replace a
/// primitive without changing the meaning carried by a view.
enum DaydayThemeRole: CaseIterable {
  case action, recording, success, warning, destructive, failure
  case evidenceObjective, evidenceInference, evidenceCorrection
  case selectionFill, selectionBorder
  case textPrimary, textSecondary, textTertiary
  case surfaceCanvas, surfaceRaised, surfaceInset
  case controlFill, controlBorder, separator, focus
}

struct DaydayRGBA: Equatable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
  let opacity: Double

  init(_ red: Double, _ green: Double, _ blue: Double, opacity: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.opacity = opacity
  }

  var color: Color { Color(red: red, green: green, blue: blue, opacity: opacity) }

  func contrastRatio(against background: DaydayRGBA) -> Double {
    let lighter = relativeLuminance
    let darker = background.relativeLuminance
    return (max(lighter, darker) + 0.05) / (min(lighter, darker) + 0.05)
  }

  private var relativeLuminance: Double {
    func linear(_ component: Double) -> Double {
      component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }
}

enum DaydayThemeAppearance: Sendable { case light, dark }
enum DaydayThemeContrast: Sendable { case standard, increased }

struct DaydayThemeEnvironment: Sendable {
  var appearance: DaydayThemeAppearance
  var contrast: DaydayThemeContrast
  var reduceTransparency: Bool
}

struct DaydayTheme {
  private let values: [DaydayThemeRole: DaydayRGBA]

  subscript(_ role: DaydayThemeRole) -> Color { values[role]!.color }
  func primitive(_ role: DaydayThemeRole) -> DaydayRGBA { values[role]! }

  static func mineralCandidate(
    for environment: DaydayThemeEnvironment,
    accent: AppearanceSettingsModel.Accent = .systemBlue
  ) -> DaydayTheme {
    let primitives =
      environment.appearance == .dark
      ? MineralCandidateTheme.dark
      : MineralCandidateTheme.light
    var values = primitives.values
    let accentPrimitive = configuredAccent(accent, appearance: environment.appearance)

    values[.action] = accentPrimitive
    values[.evidenceInference] = accentPrimitive
    values[.selectionFill] = DaydayRGBA(
      accentPrimitive.red,
      accentPrimitive.green,
      accentPrimitive.blue,
      opacity: environment.appearance == .dark ? 0.20 : 0.13
    )
    values[.selectionBorder] = accentPrimitive
    values[.focus] = accentPrimitive

    if environment.contrast == .increased {
      values[.separator] = primitives.strongSeparator
      values[.controlBorder] = primitives.strongSeparator
      values[.focus] = primitives.focusStrong
      values[.textTertiary] = primitives.highContrastTertiary
      values[.warning] = primitives.highContrastWarning
    }
    if environment.reduceTransparency {
      values[.surfaceRaised] = primitives.solidRaised
    }
    return DaydayTheme(values: values)
  }

  private static func configuredAccent(
    _ accent: AppearanceSettingsModel.Accent,
    appearance: DaydayThemeAppearance
  ) -> DaydayRGBA {
    switch (accent, appearance) {
    case (.systemBlue, .light): DaydayRGBA(0.00, 0.48, 1.00)
    case (.systemBlue, .dark): DaydayRGBA(0.38, 0.64, 1.00)
    case (.lavender, .light): DaydayRGBA(0.48, 0.39, 0.88)
    case (.lavender, .dark): DaydayRGBA(0.64, 0.57, 1.00)
    case (.rose, .light): DaydayRGBA(0.85, 0.34, 0.56)
    case (.rose, .dark): DaydayRGBA(0.96, 0.50, 0.68)
    case (.coral, .light): DaydayRGBA(0.88, 0.30, 0.27)
    case (.coral, .dark): DaydayRGBA(0.98, 0.46, 0.42)
    }
  }
}

/// The sole home for candidate literal palette primitives. These values are a
/// calibration proposal, not product identity or a persistent user setting.
private enum MineralCandidateTheme {
  struct Palette {
    let values: [DaydayThemeRole: DaydayRGBA]
    let solidRaised: DaydayRGBA
    let strongSeparator: DaydayRGBA
    let focusStrong: DaydayRGBA
    let highContrastTertiary: DaydayRGBA
    let highContrastWarning: DaydayRGBA
  }

  static let light = Palette(
    values: [
      .action: DaydayRGBA(0.17, 0.34, 0.61), .recording: DaydayRGBA(0.10, 0.42, 0.25),
      .success: DaydayRGBA(0.18, 0.45, 0.31), .warning: DaydayRGBA(0.52, 0.30, 0.05),
      .destructive: DaydayRGBA(0.70, 0.20, 0.18), .failure: DaydayRGBA(0.61, 0.13, 0.13),
      .evidenceObjective: DaydayRGBA(0.16, 0.41, 0.56),
      .evidenceInference: DaydayRGBA(0.39, 0.32, 0.62),
      .evidenceCorrection: DaydayRGBA(0.61, 0.31, 0.10),
      .selectionFill: DaydayRGBA(0.17, 0.34, 0.61, opacity: 0.13),
      .selectionBorder: DaydayRGBA(0.17, 0.34, 0.61),
      .textPrimary: DaydayRGBA(0.12, 0.14, 0.16), .textSecondary: DaydayRGBA(0.31, 0.34, 0.37),
      .textTertiary: DaydayRGBA(0.36, 0.39, 0.40), .surfaceCanvas: DaydayRGBA(0.94, 0.94, 0.92),
      .surfaceRaised: DaydayRGBA(0.985, 0.985, 0.975), .surfaceInset: DaydayRGBA(0.89, 0.90, 0.88),
      .controlFill: DaydayRGBA(0.91, 0.92, 0.90),
      .controlBorder: DaydayRGBA(0.57, 0.59, 0.57, opacity: 0.65),
      .separator: DaydayRGBA(0.53, 0.55, 0.53, opacity: 0.38), .focus: DaydayRGBA(0.12, 0.35, 0.76),
    ],
    solidRaised: DaydayRGBA(0.985, 0.985, 0.975),
    strongSeparator: DaydayRGBA(0.31, 0.34, 0.36),
    focusStrong: DaydayRGBA(0.05, 0.24, 0.68),
    highContrastTertiary: DaydayRGBA(0.24, 0.27, 0.28),
    highContrastWarning: DaydayRGBA(0.42, 0.22, 0.03)
  )

  static let dark = Palette(
    values: [
      .action: DaydayRGBA(0.52, 0.68, 0.94), .recording: DaydayRGBA(0.42, 0.78, 0.53),
      .success: DaydayRGBA(0.43, 0.76, 0.55), .warning: DaydayRGBA(0.92, 0.64, 0.25),
      .destructive: DaydayRGBA(0.98, 0.48, 0.43), .failure: DaydayRGBA(0.98, 0.48, 0.43),
      .evidenceObjective: DaydayRGBA(0.43, 0.72, 0.87),
      .evidenceInference: DaydayRGBA(0.68, 0.58, 0.93),
      .evidenceCorrection: DaydayRGBA(0.92, 0.58, 0.29),
      .selectionFill: DaydayRGBA(0.52, 0.68, 0.94, opacity: 0.20),
      .selectionBorder: DaydayRGBA(0.52, 0.68, 0.94),
      .textPrimary: DaydayRGBA(0.91, 0.92, 0.90), .textSecondary: DaydayRGBA(0.70, 0.72, 0.70),
      .textTertiary: DaydayRGBA(0.54, 0.57, 0.55), .surfaceCanvas: DaydayRGBA(0.105, 0.12, 0.12),
      .surfaceRaised: DaydayRGBA(0.145, 0.16, 0.16), .surfaceInset: DaydayRGBA(0.09, 0.105, 0.105),
      .controlFill: DaydayRGBA(0.19, 0.21, 0.20),
      .controlBorder: DaydayRGBA(0.54, 0.57, 0.55, opacity: 0.70),
      .separator: DaydayRGBA(0.62, 0.65, 0.62, opacity: 0.34), .focus: DaydayRGBA(0.50, 0.70, 1.00),
    ],
    solidRaised: DaydayRGBA(0.145, 0.16, 0.16),
    strongSeparator: DaydayRGBA(0.82, 0.84, 0.82),
    focusStrong: DaydayRGBA(0.62, 0.78, 1.00),
    highContrastTertiary: DaydayRGBA(0.82, 0.84, 0.82),
    highContrastWarning: DaydayRGBA(1.00, 0.72, 0.35)
  )
}

enum DaydayType {
  static let pageTitle = Font.system(.title2, design: .default, weight: .semibold)
  static let sectionTitle = Font.system(.headline, design: .default, weight: .semibold)
  static let body = Font.system(.body, design: .default)
  static let detail = Font.system(.callout, design: .default)
  static let metadata = Font.system(.caption, design: .default).monospacedDigit()
  static let micro = Font.system(.caption2, design: .default).monospacedDigit()
}

enum DaydaySpace {
  static let xs: CGFloat = 4
  static let s: CGFloat = 8
  static let m: CGFloat = 12
  static let l: CGFloat = 16
  static let xl: CGFloat = 24
  static let page: CGFloat = 28
  static let pageHorizontal: CGFloat = 20
  static let pageTop: CGFloat = 12
  static let pageHeaderBottom: CGFloat = 0
  static let pageContentTop: CGFloat = 8
  static let pageHeaderMinimumHeight: CGFloat = 44
}
enum DaydayRadius {
  static let control: CGFloat = 8
  static let partition: CGFloat = 12
  static let chrome: CGFloat = 16
}
enum DaydayDepth {
  static let hairline: CGFloat = 0.5
  static let partitionShadow: CGFloat = 2
}
enum DaydayMotionTransition: Equatable {
  case compact, spatial, crossfade, staticChange

  var animation: Animation? {
    switch self {
    case .compact: .easeOut(duration: 0.20)
    case .spatial: .spring(response: 0.34, dampingFraction: 1.0)
    case .crossfade: .easeOut(duration: 0.15)
    case .staticChange: nil
    }
  }
}

struct DaydayMotionPolicy: Equatable {
  let compact: DaydayMotionTransition
  let spatial: DaydayMotionTransition

  static func forAccessibility(reduceMotion: Bool) -> DaydayMotionPolicy {
    reduceMotion
      ? .init(compact: .crossfade, spatial: .staticChange)
      : .init(compact: .compact, spatial: .spatial)
  }
}

struct DaydayMotionReader<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ViewBuilder var content: (DaydayMotionPolicy) -> Content

  var body: some View { content(.forAccessibility(reduceMotion: reduceMotion)) }
}

/// One interruptible cadence for live keyboard and pointer totals across
/// Today, Insights, and the menu-bar dashboard. Heatmap cells deliberately do
/// not replay this animation for every event; their intensity updates directly
/// so rapid typing remains lightweight.
enum DaydayLiveMetricMotion {
  enum Style: Equatable {
    case snappy
    case reducedCrossfade
  }

  static let snappyDuration: TimeInterval = 0.24
  static let reducedMotionDuration: TimeInterval = 0.12

  static func style(reduceMotion: Bool) -> Style {
    reduceMotion ? .reducedCrossfade : .snappy
  }

  static func animation(reduceMotion: Bool) -> Animation {
    switch style(reduceMotion: reduceMotion) {
    case .snappy:
      .snappy(duration: snappyDuration)
    case .reducedCrossfade:
      .easeOut(duration: reducedMotionDuration)
    }
  }

  static func contentTransition(reduceMotion: Bool) -> ContentTransition {
    reduceMotion ? .opacity : .numericText()
  }
}

private struct DaydayLiveMetricValueModifier<Value: Equatable>: ViewModifier {
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .contentTransition(
        DaydayLiveMetricMotion.contentTransition(reduceMotion: reduceMotion)
      )
      .animation(
        DaydayLiveMetricMotion.animation(reduceMotion: reduceMotion),
        value: value
      )
  }
}

extension View {
  func daydayLiveMetricValue<Value: Equatable>(_ value: Value) -> some View {
    modifier(DaydayLiveMetricValueModifier(value: value))
  }
}

enum DaydayBarGrowthAxis: Hashable {
  case horizontal
  case vertical
}

/// A layout-stable growth animation shared by objective bar charts.
///
/// The bar content is always laid out at its final size. Only its compositor
/// scale changes, so live duration updates do not repeatedly resize the parent
/// chart or trigger application-data work. One short, interruptible task runs
/// only when the normalized value changes; Reduce Motion updates immediately.
struct DaydayGrowingBar<BarContent: View>: View {
  let fraction: CGFloat
  let axis: DaydayBarGrowthAxis
  let minimumVisibleLength: CGFloat
  let animates: Bool
  @ViewBuilder let barContent: BarContent

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var displayedFraction: CGFloat = 0

  init(
    fraction: CGFloat,
    axis: DaydayBarGrowthAxis,
    minimumVisibleLength: CGFloat = 0,
    animates: Bool = true,
    @ViewBuilder barContent: () -> BarContent
  ) {
    self.fraction = fraction
    self.axis = axis
    self.minimumVisibleLength = minimumVisibleLength
    self.animates = animates
    self.barContent = barContent()
  }

  var body: some View {
    GeometryReader { proxy in
      let visibleFraction = visibleFraction(in: proxy.size)
      barContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(
          x: axis == .horizontal ? visibleFraction : 1,
          y: axis == .vertical ? visibleFraction : 1,
          anchor: axis == .horizontal ? .leading : .bottom
        )
    }
    .task(
      id: DaydayBarGrowthAnimationIdentity(
        fraction: targetFraction,
        reduceMotion: reduceMotion,
        animates: animates
      )
    ) {
      let target = targetFraction
      if reduceMotion || !animates {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { displayedFraction = target }
        return
      }

      if displayedFraction == 0, target > 0 {
        await Task.yield()
        guard !Task.isCancelled else { return }
      }
      withAnimation(DaydayLiveMetricMotion.animation(reduceMotion: false)) {
        displayedFraction = target
      }
    }
  }

  private var targetFraction: CGFloat {
    guard fraction.isFinite else { return 0 }
    return min(1, max(0, fraction))
  }

  private func visibleFraction(in size: CGSize) -> CGFloat {
    guard displayedFraction > 0 else { return 0 }
    let availableLength = axis == .horizontal ? size.width : size.height
    guard availableLength > 0 else { return displayedFraction }
    return min(
      1,
      max(displayedFraction, max(0, minimumVisibleLength) / availableLength)
    )
  }
}

private struct DaydayBarGrowthAnimationIdentity: Hashable {
  let fraction: CGFloat
  let reduceMotion: Bool
  let animates: Bool
}

/// Shared visual and motion rules for every Dayday heatmap.
///
/// The scale is continuous rather than a set of named buckets. A logarithmic curve keeps small
/// non-zero values visible when one unusually busy cell would otherwise flatten the rest of the
/// grid. The same curve feeds cells and legends, so the key never implies thresholds that do not
/// exist in the data.
enum DaydayHeatmapScale {
  static let emptyOpacity = 0.075
  static let minimumActiveOpacity = 0.18
  static let maximumActiveOpacity = 0.86

  static func intensity(value: Double, maximum: Double) -> Double {
    guard value > 0, maximum > 0 else { return 0 }
    return min(1, log1p(value) / log1p(maximum))
  }

  static func color(tint: Color, value: Double, maximum: Double) -> Color {
    guard value > 0, maximum > 0 else { return Color.secondary.opacity(emptyOpacity) }
    let normalized = intensity(value: value, maximum: maximum)
    return tint.opacity(
      minimumActiveOpacity + normalized * (maximumActiveOpacity - minimumActiveOpacity))
  }

  /// Interaction counts often contain one unusually busy hour. Unlike the
  /// general logarithmic scale, the activity heatmap uses a robust P10–P90
  /// domain so ordinary hours retain visible separation while remaining a
  /// continuous, theme-tinted scale.
  static func activityColor(tint: Color, value: UInt64, values: [UInt64]) -> Color {
    guard value > 0 else { return Color.secondary.opacity(emptyOpacity) }
    let intensity = ActivityHeatmapContrast.intensity(value: value, values: values)
    return tint.opacity(0.20 + intensity * 0.76)
  }

  /// Continuous color for a measured metric whose meaningful domain does not necessarily begin at
  /// zero (for example heart rate). Empty cells stay neutral; present values remain strictly
  /// ordered between the observed minimum and maximum without introducing named buckets.
  static func color(
    tint: Color,
    value: Double?,
    minimum: Double,
    maximum: Double,
    logarithmic: Bool
  ) -> Color {
    guard let value, value.isFinite else { return Color.secondary.opacity(emptyOpacity) }
    let normalized: Double
    if maximum > minimum {
      let linear = min(1, max(0, (value - minimum) / (maximum - minimum)))
      normalized = logarithmic ? log1p(linear * 9) / log(10) : linear
    } else {
      normalized = 0.62
    }
    return tint.opacity(
      minimumActiveOpacity + normalized * (maximumActiveOpacity - minimumActiveOpacity))
  }

  static func gradientStops(tint: Color, sampleCount: Int = 13) -> [Gradient.Stop] {
    let safeCount = max(2, sampleCount)
    return (0..<safeCount).map { index in
      let location = Double(index) / Double(safeCount - 1)
      return Gradient.Stop(
        color: color(tint: tint, value: location, maximum: 1),
        location: location
      )
    }
  }

  static func measuredMetricGradientStops(tint: Color, sampleCount: Int = 13) -> [Gradient.Stop] {
    let safeCount = max(2, sampleCount)
    return (0..<safeCount).map { index in
      let location = Double(index) / Double(safeCount - 1)
      return Gradient.Stop(
        color: color(
          tint: tint,
          value: location,
          minimum: 0,
          maximum: 1,
          logarithmic: true
        ),
        location: location
      )
    }
  }
}

/// Pure timing for the shared vertical wave reveal.
///
/// One global value is animated, then each heatmap cell derives a local phase from its horizontal
/// column and a small row offset. Cells therefore rise vertically while the crest travels through
/// the grid; they are not exposed by a horizontal clipping mask. Reduce Motion removes all spatial
/// displacement and retains only a short uniform fade.
enum DaydayHeatmapWaveMotion {
  static let compactDuration: TimeInterval = 0.44
  static let wideDuration: TimeInterval = 0.62
  static let reducedMotionDuration: TimeInterval = 0.15

  private static let columnTravel = 0.88
  private static let localRevealSpan = 0.085
  private static let rowOffsets = [0.000, 0.006, 0.014, 0.020, 0.015, 0.008, 0.002]

  static func animationDuration(columnCount: Int, reduceMotion: Bool) -> TimeInterval {
    guard !reduceMotion else { return reducedMotionDuration }
    let normalizedWidth = min(1, max(0, Double(columnCount - 5) / 48))
    return compactDuration + (wideDuration - compactDuration) * normalizedWidth
  }

  static func phase(column: Int, row: Int, columnCount: Int) -> Double {
    let safeColumnCount = max(1, columnCount)
    let safeColumn = min(max(0, column), safeColumnCount - 1)
    let denominator = max(1, safeColumnCount - 1)
    let columnPhase = Double(safeColumn) / Double(denominator) * columnTravel
    let rowPhase = rowOffsets[positiveModulo(row, rowOffsets.count)]
    return min(1, columnPhase + rowPhase)
  }

  static func cellProgress(
    globalProgress: Double,
    column: Int,
    row: Int,
    columnCount: Int,
    reduceMotion: Bool
  ) -> Double {
    let clampedProgress = min(1, max(0, globalProgress))
    guard !reduceMotion else { return clampedProgress }
    let start = phase(column: column, row: row, columnCount: columnCount)
    let local = min(1, max(0, (clampedProgress - start) / localRevealSpan))
    return local * local * (3 - 2 * local)
  }

  static func cellScale(revealProgress: Double, reduceMotion: Bool) -> Double {
    guard !reduceMotion else { return 1 }
    let progress = min(1, max(0, revealProgress))
    return 0.92 + progress * 0.08
  }

  static func cellVerticalOffset(revealProgress: Double, reduceMotion: Bool) -> Double {
    guard !reduceMotion else { return 0 }
    let progress = min(1, max(0, revealProgress))
    return (1 - progress) * 0.45
  }

  private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
  }
}

/// Runs one interruptible reveal for a heatmap appearance or filter identity.
///
/// Callers keep data fetching separate and pass only a cheap, stable identity. Live data refreshes
/// therefore do not need to replay the animation unless the product explicitly changes that key.
struct DaydayHeatmapWaveReveal<ID: Hashable, Content: View>: View {
  let runID: ID
  let columnCount: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var revealProgress = 0.0
  private let content: (Double, Bool) -> Content

  init(
    runID: ID,
    columnCount: Int,
    @ViewBuilder content: @escaping (Double, Bool) -> Content
  ) {
    self.runID = runID
    self.columnCount = columnCount
    self.content = content
  }

  var body: some View {
    content(revealProgress, reduceMotion)
      .task(id: RunIdentity(runID: runID, reduceMotion: reduceMotion)) {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { revealProgress = 0 }
        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(
          .easeOut(
            duration: DaydayHeatmapWaveMotion.animationDuration(
              columnCount: columnCount,
              reduceMotion: reduceMotion
            ))
        ) {
          revealProgress = 1
        }
      }
  }

  private struct RunIdentity: Hashable {
    let runID: ID
    let reduceMotion: Bool
  }
}

/// Animatable cell boundary used by non-Canvas heatmaps.
struct DaydayHeatmapWaveCellModifier: @preconcurrency AnimatableModifier {
  var revealProgress: Double
  let column: Int
  let row: Int
  let columnCount: Int
  let rowStep: CGFloat
  let reduceMotion: Bool

  var animatableData: Double {
    get { revealProgress }
    set { revealProgress = newValue }
  }

  func body(content: Content) -> some View {
    let progress = DaydayHeatmapWaveMotion.cellProgress(
      globalProgress: revealProgress,
      column: column,
      row: row,
      columnCount: columnCount,
      reduceMotion: reduceMotion
    )
    return
      content
      .opacity(progress)
      .scaleEffect(
        DaydayHeatmapWaveMotion.cellScale(
          revealProgress: progress,
          reduceMotion: reduceMotion
        )
      )
      .offset(
        y: DaydayHeatmapWaveMotion.cellVerticalOffset(
          revealProgress: progress,
          reduceMotion: reduceMotion
        ) * rowStep
      )
  }
}

extension View {
  func daydayHeatmapWaveCell(
    revealProgress: Double,
    column: Int,
    row: Int,
    columnCount: Int,
    rowStep: CGFloat,
    reduceMotion: Bool
  ) -> some View {
    modifier(
      DaydayHeatmapWaveCellModifier(
        revealProgress: revealProgress,
        column: column,
        row: row,
        columnCount: columnCount,
        rowStep: rowStep,
        reduceMotion: reduceMotion
      ))
  }
}

/// Compact, continuous legend shared by the full-size heatmaps.
struct DaydayHeatmapContinuousLegend: View {
  let title: String
  let tint: Color
  var minimumLabel = "0"
  let maximumLabel: String
  let unitDetail: String
  var usesMeasuredMetricScale = false
  var showsTitle = true

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DaydaySpace.s) { legendContent }
      VStack(alignment: .leading, spacing: DaydaySpace.xs) { legendContent }
    }
    .font(DaydayType.metadata)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      title.isEmpty
        ? "连续色阶，从 \(minimumLabel) 到 \(maximumLabel)，\(unitDetail)"
        : "\(title)，连续色阶，从 \(minimumLabel) 到 \(maximumLabel)，\(unitDetail)"
    )
  }

  @ViewBuilder
  private var legendContent: some View {
    if showsTitle {
      Text(title)
    }
    HStack(spacing: DaydaySpace.xs) {
      Text(minimumLabel)
      RoundedRectangle(cornerRadius: 3, style: .continuous)
        .fill(
          LinearGradient(
            stops: usesMeasuredMetricScale
              ? DaydayHeatmapScale.measuredMetricGradientStops(tint: tint)
              : DaydayHeatmapScale.gradientStops(tint: tint),
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(width: 132, height: 11)
        .accessibilityHidden(true)
      Text(maximumLabel)
        .monospacedDigit()
    }
    Spacer(minLength: 0)
    Text(unitDetail)
  }
}

/// Stable hover readout. It avoids a tooltip chasing the pointer across a dense grid while still
/// keeping exact values out of the heatmap cells until the user asks for them with the pointer.
struct DaydayHeatmapHoverSummary: View {
  let text: String
  let isActive: Bool
  var activeSystemImage = "clock"
  var activeTint: Color = .accentColor

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: isActive ? activeSystemImage : "cursorarrow.rays")
        .foregroundStyle(isActive ? activeTint : Color.secondary)
        .accessibilityHidden(true)
      Text(text)
        .font(DaydayType.metadata)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
    .animation(.easeOut(duration: 0.12), value: text)
  }
}

/// Responsive geometry for a Monday-first calendar heatmap. The grid stays compact on a wide
/// dashboard and shrinks continuously on narrow windows instead of becoming a fixed-width scroller.
struct DaydayCalendarHeatmapLayout: Equatable {
  let cellSize: CGFloat
  let columnSpacing: CGFloat
  let rowSpacing: CGFloat
  let columnCount: Int
  let rowCount: Int

  var width: CGFloat {
    CGFloat(columnCount) * cellSize + CGFloat(max(0, columnCount - 1)) * columnSpacing
  }

  var height: CGFloat {
    CGFloat(rowCount) * cellSize + CGFloat(max(0, rowCount - 1)) * rowSpacing
  }

  static func fitting(
    availableWidth: CGFloat,
    columnCount: Int,
    rowCount: Int = 7,
    maximumCellSize: CGFloat = 11
  ) -> Self {
    let safeColumns = max(1, columnCount)
    let safeRows = max(1, rowCount)
    let spacingRatio = 0.24
    let denominator = CGFloat(safeColumns) + CGFloat(max(0, safeColumns - 1)) * spacingRatio
    let rawCell = max(0, availableWidth) / max(1, denominator)
    let cell = min(maximumCellSize, max(4.5, floor(rawCell * 2) / 2))
    let spacing = max(1.5, min(2.75, cell * spacingRatio))
    return Self(
      cellSize: cell,
      columnSpacing: spacing,
      rowSpacing: spacing,
      columnCount: safeColumns,
      rowCount: safeRows
    )
  }
}

struct DaydayThemeReader<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.daydayAccent) private var accent
  @ViewBuilder var content: (DaydayTheme, Bool) -> Content

  var body: some View {
    content(
      .mineralCandidate(
        for: .init(
          appearance: colorScheme == .dark ? .dark : .light,
          contrast: contrast == .increased ? .increased : .standard,
          reduceTransparency: reduceTransparency
        ),
        accent: accent
      ),
      reduceTransparency
    )
  }
}
