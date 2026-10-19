import SwiftUI

struct LocalHealthFactsView: View {
    let facts: [HealthFactRecord]

    var body: some View {
        List(facts) { fact in
            VStack(alignment: .leading, spacing: 5) {
                Text(fact.kind.title)
                    .font(.headline)
                Text(payloadDescription(for: fact.payload))
                    .font(.body)
                Text(fact.startDate, format: .dateTime.year().month().day().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(fact.sourceName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .overlay {
            if facts.isEmpty {
                ContentUnavailableView(
                    "尚无本机健康事实",
                    systemImage: "heart.text.square",
                    description: Text("请求读取授权后，点击“读取已授权健康数据”。")
                )
            }
        }
        .navigationTitle("本机健康事实")
    }

    private func payloadDescription(for payload: HealthFactRecord.Payload) -> String {
        switch payload {
        case let .quantity(value, unit):
            return "\(value.formatted()) \(unit)"
        case let .category(rawValue):
            return "分类值 \(rawValue)"
        case let .workout(activityType, duration, activeEnergyKilocalories):
            var text = "活动类型 \(activityType) · \(duration.formatted()) 秒"
            if let activeEnergyKilocalories {
                text += " · \(activeEnergyKilocalories.formatted()) kcal"
            }
            return text
        }
    }
}
