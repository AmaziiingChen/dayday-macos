import SwiftUI

enum ApplicationDurationChartStyle: String, CaseIterable, Identifiable {
    case bar = "柱状图"
    case pie = "饼图"

    var id: Self { self }
}

/// An objective frontmost-application duration chart. It deliberately renders
/// only duration and named application summaries; input events stay outside
/// this visualization because they are retained as device-wide totals.
struct ApplicationDurationChart: View {
    let summaries: [ApplicationUsagePresentation.Summary]
    let style: ApplicationDurationChartStyle

    private var stableChartHeight: CGFloat {
        let count = max(1, summaries.count)
        let barHeight = CGFloat(count * 19) + CGFloat(max(0, count - 1) * 9) + 8
        return max(210, barHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ApplicationDurationBarChart(summaries: summaries, animates: style == .bar)
                .opacity(style == .bar ? 1 : 0)
                .allowsHitTesting(style == .bar)
            ApplicationDurationPieChart(summaries: summaries)
                .opacity(style == .pie ? 1 : 0)
                .allowsHitTesting(style == .pie)
        }
        // Both small native render trees stay mounted. Switching therefore
        // changes only visibility, not the hosting view's constraints or
        // accessibility hierarchy while AppKit is completing the click.
        .frame(minHeight: stableChartHeight, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("应用时长分布")
    }
}

private struct ApplicationDurationBarChart: View {
    let summaries: [ApplicationUsagePresentation.Summary]
    let animates: Bool
    @Environment(\.daydayAccent) private var accent

    private var maximum: TimeInterval {
        summaries.map(\.duration).max() ?? 1
    }

    var body: some View {
        VStack(spacing: 9) {
            ForEach(summaries) { summary in
                HStack(spacing: 12) {
                    Text(summary.displayLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 148, alignment: .trailing)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.07))
                        DaydayGrowingBar(
                            fraction: CGFloat(summary.duration / maximum),
                            axis: .horizontal,
                            minimumVisibleLength: 3,
                            animates: animates
                        ) {
                            Capsule()
                                .fill(accent.tint)
                        }
                    }
                    .frame(height: 10)
                    Text(summary.duration.durationText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(summary.displayLabel)，\(summary.duration.durationText)，\(summary.intervalCount) 个前台时段")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ApplicationDurationPieChart: View {
    let summaries: [ApplicationUsagePresentation.Summary]
    @Environment(\.daydayAccent) private var accent

    private struct Slice: Identifiable {
        let index: Int
        let summary: ApplicationUsagePresentation.Summary
        let startFraction: Double
        let endFraction: Double

        var id: UUID { summary.id }
    }

    private let total: TimeInterval
    private let slices: [Slice]

    init(summaries: [ApplicationUsagePresentation.Summary]) {
        self.summaries = summaries
        let total = max(1, summaries.reduce(0) { $0 + $1.duration })
        self.total = total
        var cursor = 0.0
        self.slices = summaries.enumerated().map { index, summary in
            let start = cursor
            cursor += summary.duration / total
            return Slice(
                index: index,
                summary: summary,
                startFraction: start,
                endFraction: cursor
            )
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            ZStack {
                ForEach(slices) { slice in
                    ApplicationDurationPieSlice(
                        startFraction: slice.startFraction,
                        endFraction: slice.endFraction
                    )
                    .fill(ApplicationDurationChartColor.color(for: slice.index, tint: accent.tint))
                }
            }
            .frame(width: 210, height: 210)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("应用时长饼图，共 \(summaries.count) 个应用")

            LazyVGrid(
                columns: [GridItem(.flexible(minimum: 150)), GridItem(.flexible(minimum: 150))],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(ApplicationDurationChartColor.color(for: index, tint: accent.tint))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.displayLabel)
                                .lineLimit(1)
                            Text("\(summary.duration.durationText) · \(share(for: summary))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func share(for summary: ApplicationUsagePresentation.Summary) -> String {
        "\(Int((summary.duration / total * 100).rounded()))%"
    }
}

private struct ApplicationDurationPieSlice: Shape {
    let startFraction: Double
    let endFraction: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        guard endFraction > startFraction else { return Path() }
        let start = Angle.degrees((startFraction * 360) - 90)
        let end = Angle.degrees((endFraction * 360) - 90)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}

private enum ApplicationDurationChartColor {
    private static let opacities = [1.0, 0.82, 0.66, 0.52, 0.40]

    static func color(for index: Int, tint: Color) -> Color {
        tint.opacity(opacities[index % opacities.count])
    }
}
