import SwiftUI

struct HealthCompanionRootView: View {
    @ObservedObject var model: HealthCompanionModel

    var body: some View {
        NavigationStack {
            List {
                Section("健康读取") {
                    LabeledContent("HealthKit") {
                        Text(model.authorizationPresentation.title)
                    }

                    ForEach(HealthReadGroup.allCases) { group in
                        DisclosureGroup {
                            ForEach(HealthReadCatalog.kinds(in: group)) { kind in
                                LabeledContent(kind.title) {
                                    Text(model.syncPlan.lastCompletedRead(at: kind) == nil
                                        ? "尚未核对"
                                        : "已核对")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } label: {
                            Label(
                                "\(group.title) · \(checkedKinds(in: group))/\(HealthReadCatalog.kinds(in: group).count) 项已核对",
                                systemImage: group.symbolName
                            )
                        }
                    }

                    Text("只读取你授权的健康样本并保存到本机受保护队列；不会上传或写回 Apple 健康。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("请求读取授权") {
                        model.requestReadAuthorization()
                    }
                    .disabled(model.authorizationPresentation == .unavailable)

                    Button("读取已授权健康数据") {
                        model.importAuthorizedHealthFacts()
                    }
                    .disabled(model.authorizationPresentation == .unavailable || model.importPresentation == .importing)

                    LabeledContent("本机读取") {
                        Text(model.importPresentation.title)
                    }

                    LabeledContent("本机事实") {
                        Text("\(model.localFactCount) 条")
                    }

                    NavigationLink("查看本机健康事实") {
                        LocalHealthFactsView(facts: model.recentFacts)
                    }

                    NavigationLink("查看读取覆盖情况") {
                        HealthReadCoverageView(
                            plan: model.syncPlan,
                            coverageByKind: model.coverageByKind
                        )
                    }

                    if model.localTombstoneCount > 0 {
                        LabeledContent("删除记录") {
                            Text("\(model.localTombstoneCount) 条")
                        }
                    }

                    LabeledContent("后台更新") {
                        Text(model.backgroundObservationState.title)
                    }
                }

                Section("本地同步准备") {
                    LabeledContent("待导入类型") {
                        Text(model.syncPlan.requestedTypes.isEmpty ? "尚无" : "\(model.syncPlan.requestedTypes.count) 项")
                    }

                    if let queuedAt = model.syncPlan.initialImportQueuedAt {
                        LabeledContent("首次导入计划") {
                            Text(queuedAt, format: .dateTime.year().month().day().hour().minute())
                        }
                    }

                    if let requestedAt = model.syncPlan.lastManualSyncRequestAt {
                        LabeledContent("最近手动同步请求") {
                            Text(requestedAt, format: .dateTime.year().month().day().hour().minute())
                        }
                    }

                    LabeledContent("同步状态") {
                        Text(model.localSyncPresentation.title)
                            .multilineTextAlignment(.trailing)
                    }

                    if case .notPaired = model.localSyncPresentation {
                        TextField("粘贴 Mac 配对码", text: $model.pairingCodeInput, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...4)
                        Button("保存配对并同步", systemImage: "lock.shield") {
                            model.savePairingCodeAndSync()
                        }
                        .disabled(model.pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("忘记此 Mac", role: .destructive) {
                            model.forgetPairedMac()
                        }
                    }

                    Button("立即同步") {
                        model.markManualSyncRequested()
                    }

                    Text("首次需在 Mac 健康页面主动准备配对码。配对后仅通过同一 Wi‑Fi 的加密连接同步；Mac 成功写入并确认前，iPhone 不会清除待同步变更。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dayday Health")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        model.refreshAuthorizationRequestStatus()
                    }
                }
            }
        }
    }

    private func checkedKinds(in group: HealthReadGroup) -> Int {
        HealthReadCatalog.kinds(in: group).filter {
            model.syncPlan.lastCompletedRead(at: $0) != nil
        }.count
    }
}
