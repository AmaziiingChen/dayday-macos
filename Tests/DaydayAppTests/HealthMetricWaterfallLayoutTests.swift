import Foundation
import Testing

@testable import DaydayApp

struct HealthMetricWaterfallLayoutTests {
  @Test("Responsive waterfall honors the approved one-to-four column breakpoints")
  func responsiveBreakpoints() {
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 519) == 1)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 520) == 2)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 779) == 2)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 780) == 3)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 1_039) == 3)
    #expect(HealthMetricWaterfallDistribution.columnCount(for: 1_040) == 4)
  }

  @Test("Expanded metric spans two columns while compact cards stay bounded and non-overlapping")
  func expandedSpanPlacement() {
    let plan = HealthMetricWaterfallPlacementPlanner.plan(
      availableWidth: 1_120,
      spacing: 12,
      items: [
        .init(height: 204),
        .init(span: 2, height: 352),
        .init(height: 224),
        .init(height: 204),
        .init(height: 204),
        .init(height: 224),
      ]
    )

    #expect(plan.items.count == 6)
    #expect(plan.items[1].frame.width > plan.items[0].frame.width * 1.9)
    #expect(plan.items.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 1_120 })
    #expect(plan.items.allSatisfy { $0.frame.minY >= 0 && $0.frame.maxY <= plan.size.height })

    for firstIndex in plan.items.indices {
      for secondIndex in plan.items.indices where secondIndex > firstIndex {
        #expect(!plan.items[firstIndex].frame.intersects(plan.items[secondIndex].frame))
      }
    }
  }

  @Test("Expanded metric becomes full width when the window has one column")
  func narrowExpandedPlacement() {
    let plan = HealthMetricWaterfallPlacementPlanner.plan(
      availableWidth: 480,
      spacing: 12,
      items: [.init(span: 2, height: 320), .init(height: 200)]
    )

    #expect(plan.items[0].frame.width == 480)
    #expect(plan.items[1].frame.width == 480)
    #expect(plan.items[1].frame.minY == 332)
  }

  @Test("Waterfall placement is deterministic for identical inputs")
  func deterministicPlacement() {
    let items = [
      HealthMetricWaterfallPlacementPlanner.Item(height: 204),
      .init(height: 224),
      .init(span: 2, height: 352),
      .init(height: 204),
      .init(height: 224),
    ]

    let first = HealthMetricWaterfallPlacementPlanner.plan(
      availableWidth: 880,
      spacing: 12,
      items: items
    )
    let second = HealthMetricWaterfallPlacementPlanner.plan(
      availableWidth: 880,
      spacing: 12,
      items: items
    )

    #expect(first == second)
  }
}
