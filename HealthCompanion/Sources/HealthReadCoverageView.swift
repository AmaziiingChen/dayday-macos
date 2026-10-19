import SwiftUI

struct HealthReadCoverageView: View {
    let plan: HealthImportPlan
    let coverageByKind: [HealthReadKind: HealthFactCoverage]

    private var checkedKindCount: Int {
        HealthReadCatalog.kinds.filter { plan.lastCompletedRead(at: $0) != nil }.count
    }

    var body: some View {
        List {
            Section {
                LabeledContent("已核对类型") {
                    Text("\(checkedKindCount) / \(HealthReadCatalog.kinds.count) 项")
                }
                Text("“已核对但暂未发现记录”表示这类数据已完成读取，不代表 0，也不对授权状态作推断。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(HealthReadGroup.allCases) { group in
                Section(group.title) {
                    ForEach(HealthReadCatalog.kinds(in: group)) { kind in
                        HealthReadCoverageRow(
                            kind: kind,
                            checkedAt: plan.lastCompletedRead(at: kind),
                            coverage: coverageByKind[kind]
                        )
                    }
                }
            }
        }
        .navigationTitle("读取覆盖情况")
    }
}

private struct HealthReadCoverageRow: View {
    let kind: HealthReadKind
    let checkedAt: Date?
    let coverage: HealthFactCoverage?

    var body: some View {
        LabeledContent(kind.title) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(primaryStatus)
                if let date = coverage?.latestFactEndDate ?? checkedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }

    private var primaryStatus: String {
        guard checkedAt != nil else { return "尚未核对" }
        guard let coverage, coverage.factCount > 0 else { return "已核对，未发现记录" }
        return "\(coverage.factCount) 条"
    }
}
