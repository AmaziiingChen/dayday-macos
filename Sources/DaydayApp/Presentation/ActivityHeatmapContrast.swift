import Foundation

/// Pure, continuous contrast mapping for aggregate-only activity counts.
/// It is deliberately scoped to the interaction heatmap: other measured
/// heatmaps retain their own statistically meaningful domains.
enum ActivityHeatmapContrast {
  static func intensity(value: UInt64, values: [UInt64]) -> Double {
    guard value > 0 else { return 0 }
    let nonzero = values.filter { $0 > 0 }.sorted()
    guard let lower = percentile(0.10, in: nonzero), let upper = percentile(0.90, in: nonzero) else {
      return 0
    }
    guard upper > lower else { return 0.72 }
    let clamped = min(max(value, lower), upper)
    let linear = Double(clamped - lower) / Double(upper - lower)
    return sqrt(linear)
  }

  static func upperLabel(for values: [UInt64]) -> String {
    guard let upper = percentile(0.90, in: values.filter({ $0 > 0 }).sorted()) else { return "0" }
    return "\(upper) 次"
  }

  static func percentile(_ percentile: Double, in values: [UInt64]) -> UInt64? {
    guard !values.isEmpty else { return nil }
    let clamped = min(1, max(0, percentile))
    let index = Int((Double(values.count - 1) * clamped).rounded())
    return values[index]
  }
}
