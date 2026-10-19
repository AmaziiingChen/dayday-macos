import DaydayCore
import SwiftUI

enum PermissionOnboardingPresentation {
    case firstRun
    case settings
}

struct PermissionOnboardingView: View {
    @ObservedObject var model: PermissionOnboardingModel
    let presentation: PermissionOnboardingPresentation

    @State private var pendingAction: PendingAction?

    var body: some View {
        Group {
            if presentation == .firstRun {
                firstRunLayout
            } else {
                settingsLayout
            }
        }
        .confirmationDialog(
            pendingAction?.title ?? "确认操作",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(pendingAction.confirmationTitle) {
                    confirm(pendingAction)
                    self.pendingAction = nil
                }
                Button("取消", role: .cancel) {
                    self.pendingAction = nil
                }
            }
        } message: {
            if let pendingAction {
                Text(pendingAction.message)
            }
        }
    }

    private var firstRunLayout: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                firstRunNotices
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            DaydayScrollView {
                collectorList
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }

            Divider()

            firstRunFooter
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var settingsLayout: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            PrototypeNotice(
                text: "以下每一项都相互独立。查看本页、刷新状态或启动 Dayday 都不会触发 macOS 授权窗口。",
                systemImage: "hand.raised"
            )

            collectorList
        }
        .frame(maxWidth: 880, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var collectorList: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(model.displayedCollectorStates) { state in
                collectorSection(state)
            }
        }
    }

    private var firstRunNotices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("每项采集器都可以单独启用或暂不启用。", systemImage: "checklist")
            Label("查看本页和刷新状态不会触发 macOS 授权窗口。", systemImage: "lock.shield")
            Label("所有决定都能稍后在“设置 › 采集状态”中修改。", systemImage: "arrow.uturn.backward")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var firstRunFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                firstRunFooterText
                Spacer()
                postponeButton
            }
            VStack(alignment: .leading, spacing: 12) {
                firstRunFooterText
                HStack {
                    Spacer()
                    postponeButton
                }
            }
        }
    }

    private var firstRunFooterText: some View {
        Text("尚有 \(model.unconfirmedCollectorCount) 项未决定；全部作出选择后会自动完成。")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var postponeButton: some View {
        Button("稍后再决定") {
            model.dismissFirstRun()
        }
        .keyboardShortcut(.cancelAction)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                permissionPageHeader
                Spacer(minLength: 16)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 12) {
                permissionPageHeader
                refreshButton
            }
        }
    }

    private var permissionPageHeader: some View {
        Group {
            if presentation == .firstRun {
                PageHeader(
                    title: "由你决定 Dayday 记录什么",
                    subtitle: "产品内同意会在下次启动时自动恢复；macOS 系统授权由系统保留。",
                    systemImage: "checkmark.shield"
                )
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("采集器")
                        .font(.title3.weight(.semibold))
                    Text("每项均分别显示产品同意、macOS 授权与采集链路状态。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var refreshButton: some View {
        Button("刷新系统状态", systemImage: "arrow.clockwise") {
            model.refreshSystemStatuses()
        }
        .disabled(model.isRefreshing)
        .help("只读取当前权限状态，不会请求权限")
    }

    private func collectorSection(_ state: PermissionCollectorState) -> some View {
        let presentation = CollectorPresentation(state.collector)

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        collectorTitle(presentation)
                        Spacer(minLength: 12)
                        collectorBadges(state)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        collectorTitle(presentation)
                        collectorBadges(state)
                    }
                }

                Text(presentation.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            disclosureLabel("本地保留", systemImage: "internaldrive")
                            disclosureText(presentation.retained)
                        }
                        GridRow {
                            disclosureLabel("不会保留", systemImage: "nosign")
                            disclosureText(presentation.notRetained)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        disclosureLabel("本地保留", systemImage: "internaldrive")
                        disclosureText(presentation.retained)
                        disclosureLabel("不会保留", systemImage: "nosign")
                        disclosureText(presentation.notRetained)
                    }
                }

                if let message = state.message {
                    Label(message, systemImage: state.authorization.permitsCollection
                        ? "checkmark.circle"
                        : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        collectorActions(state)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        collectorActions(state)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private func collectorTitle(_ presentation: CollectorPresentation) -> some View {
        Label(presentation.title, systemImage: presentation.systemImage)
            .font(.headline)
    }

    private func collectorBadges(_ state: PermissionCollectorState) -> some View {
        HStack(spacing: 8) {
            ConsentBadge(status: state.consent)
            AuthorizationBadge(
                requirement: state.collector.consentDisclosure.permissionRequirement,
                authorization: state.authorization
            )
            CollectorDeliveryBadge(collector: state.collector)
        }
        .accessibilityElement(children: .combine)
    }

    private func disclosureLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
    }

    private func disclosureText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func collectorActions(_ state: PermissionCollectorState) -> some View {
        switch state.consent {
        case .unconfirmed:
            Button("启用", systemImage: "checkmark.circle") {
                pendingAction = .enable(state.collector)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isSavingControl)
            Button("暂不启用", systemImage: "minus.circle") {
                model.disable(state.collector)
            }
            .disabled(state.isSavingControl)
        case .disabled:
            Button("启用", systemImage: "checkmark.circle") {
                pendingAction = .enable(state.collector)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isSavingControl)
        case .enabled:
            Button("暂停", systemImage: "pause.circle") {
                model.pause(state.collector)
            }
            .disabled(state.isSavingControl)
            Button("停用", systemImage: "xmark.circle") {
                model.disable(state.collector)
            }
            .disabled(state.isSavingControl)
        case .paused:
            Button("恢复", systemImage: "play.circle") {
                model.resume(state.collector)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isSavingControl)
            Button("停用", systemImage: "xmark.circle") {
                model.disable(state.collector)
            }
            .disabled(state.isSavingControl)
        }

        if state.consent == .enabled,
           case .tcc = state.collector.consentDisclosure.permissionRequirement,
           !state.authorization.permitsCollection {
            if state.authorization == .denied
                || state.authorization == .restricted
                || state.authorization == .revoked
                || state.authorization == .insufficientAccess {
                recoveryButton(state.collector)
            } else {
                Button("请求系统权限", systemImage: "lock.open") {
                    pendingAction = .request(state.collector)
                }
                .disabled(state.isRequesting)
            }
        }

        if state.recovery != nil,
           state.consent == .enabled,
           !state.authorization.permitsCollection,
           state.authorization != .denied,
           state.authorization != .restricted,
           state.authorization != .revoked,
           state.authorization != .insufficientAccess {
            recoveryButton(state.collector)
        }

        if state.isRequesting {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("正在请求系统权限")
        }
    }

    private func recoveryButton(_ collector: CollectorKind) -> some View {
        Button("打开系统设置", systemImage: "gear") {
            model.openRecovery(for: collector)
        }
        .help("打开此权限对应的 macOS 隐私与安全性页面")
    }

    private func confirm(_ action: PendingAction) {
        switch action {
        case let .enable(collector):
            model.enable(collector)
        case let .request(collector):
            Task {
                await model.requestSystemPermission(for: collector)
            }
        }
    }
}

private enum PendingAction: Identifiable {
    case enable(CollectorKind)
    case request(CollectorKind)

    var id: String {
        switch self {
        case let .enable(collector): "enable-\(collector.rawValue)"
        case let .request(collector): "request-\(collector.rawValue)"
        }
    }

    var title: String {
        switch self {
        case let .enable(collector): "启用“\(CollectorPresentation(collector).title)”？"
        case let .request(collector): "请求“\(CollectorPresentation(collector).title)”所需的系统权限？"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .enable: "确认启用"
        case .request: "继续请求"
        }
    }

    var message: String {
        switch self {
        case let .enable(collector):
            let presentation = CollectorPresentation(collector)
            return "Dayday 将按披露保留：\(presentation.retained) 不会保留：\(presentation.notRetained) 此操作本身不会弹出 macOS 授权窗口。"
        case .request:
            return "继续后 macOS 可能显示系统授权窗口。Dayday 只会请求这一项所需的权限。"
        }
    }
}

private struct CollectorPresentation {
    let title: String
    let systemImage: String
    let purpose: String
    let retained: String
    let notRetained: String

    init(_ collector: CollectorKind) {
        switch collector {
        case .screenUnderstanding:
            self.init(
                title: "屏幕理解",
                systemImage: "rectangle.inset.filled.and.person.filled",
                purpose: "理解可见工作上下文，用于活动时间线和工作日报。",
                retained: "压缩、脱敏后的文本证据；原始画面只在分析期间短暂存在。",
                notRetained: "原始分辨率截图、排除项和密钥等敏感画面。"
            )
        case .applicationWindowContext:
            self.init(
                title: "应用与窗口上下文",
                systemImage: "macwindow.on.rectangle",
                purpose: "记录当前应用及经过隐私过滤的窗口上下文。",
                retained: "应用标识、安全的窗口提示、控件类型、显示器与状态变化。",
                notRetained: "输入框内容、密码、文档正文和安全控件内容。"
            )
        case .chromeContext:
            self.init(
                title: "Chrome 上下文",
                systemImage: "globe",
                purpose: "把当前 Chrome 页面上下文补充到工作时间线。",
                retained: "当前标签标题、规范化域名和路径、切换与音频状态。",
                notRetained: "无痕标签、查询参数、页面正文、表单值和登录状态。"
            )
        case .keyboardAggregates:
            self.init(
                title: "键盘聚合",
                systemImage: "keyboard",
                purpose: "形成客观的长期键盘活动和物理按键热力图。",
                retained: "按小时汇总的无序物理键码计数。",
                notRetained: "输入文字、按键顺序、快捷键和可还原的输入过程。"
            )
        case .pointerAggregates:
            self.init(
                title: "鼠标与触控板聚合",
                systemImage: "computermouse",
                purpose: "形成点击、滚动、移动距离和粗粒度屏幕热区统计。",
                retained: "按小时汇总的按键、滚动、估算距离和显示器网格计数。",
                notRetained: "精确坐标、逐事件时间戳和可回放的移动轨迹。"
            )
        case .calendar:
            self.init(
                title: "日历",
                systemImage: "calendar",
                purpose: "在工作时间线和日报旁展示你允许的日程上下文。",
                retained: "只读的日程时间与最少的已启用议程字段。",
                notRetained: "不会创建、修改、删除或静默共享日程。"
            )
        case .reminders:
            self.init(
                title: "提醒事项",
                systemImage: "checklist",
                purpose: "在工作时间线和日报旁展示你允许的提醒事项。",
                retained: "只读的完成状态、时间和最少的已启用字段。",
                notRetained: "不会创建、修改、删除或静默共享提醒事项。"
            )
        case .weather:
            self.init(
                title: "天气",
                systemImage: "cloud.sun",
                purpose: "为每日记录和日记增加城市级客观天气背景。",
                retained: "所选城市及配置服务商返回的天气数据。",
                notRetained: "默认不请求定位，不保存精确地址和移动轨迹。"
            )
        }
    }

    private init(
        title: String,
        systemImage: String,
        purpose: String,
        retained: String,
        notRetained: String
    ) {
        self.title = title
        self.systemImage = systemImage
        self.purpose = purpose
        self.retained = retained
        self.notRetained = notRetained
    }
}

private struct ConsentBadge: View {
    let status: CollectorConsentStatus

    var body: some View {
        StatusBadge(title: title, systemImage: systemImage, color: color)
            .accessibilityLabel("产品内状态：\(title)")
    }

    private var title: String {
        switch status {
        case .unconfirmed: "未确认"
        case .enabled: "已启用"
        case .disabled: "已停用"
        case .paused: "已暂停"
        }
    }

    private var systemImage: String {
        switch status {
        case .unconfirmed, .disabled: "circle"
        case .enabled: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .unconfirmed, .disabled: .secondary
        case .enabled: .green
        case .paused: .orange
        }
    }
}

private struct AuthorizationBadge: View {
    let requirement: CollectorPermissionRequirement
    let authorization: AuthorizationState

    var body: some View {
        StatusBadge(title: title, systemImage: systemImage, color: color)
            .accessibilityLabel("macOS 权限：\(title)")
    }

    private var title: String {
        if requirement == .notRequired { return "无需系统权限" }
        return switch authorization {
        case .authorized: "系统已授权"
        case .denied: "系统已拒绝"
        case .restricted: "系统受限"
        case .revoked: "授权已撤销"
        case .insufficientAccess: "权限不足"
        case .notDetermined: "尚未请求"
        case .unknown: "尚未授权"
        case .notRequired: "无需系统权限"
        }
    }

    private var systemImage: String {
        authorization.permitsCollection ? "checkmark.shield.fill" : "lock.shield"
    }

    private var color: Color {
        if authorization.permitsCollection { return .green }
        return switch authorization {
        case .denied, .restricted, .revoked, .insufficientAccess: .orange
        case .notDetermined, .unknown: .secondary
        case .notRequired, .authorized: .green
        }
    }
}

/// A configured consent is not evidence that an implementation has a producer behind it.
/// Keep that distinction visible until every collector has a production data path.
private struct CollectorDeliveryBadge: View {
    let collector: CollectorKind

    var body: some View {
        StatusBadge(title: title, systemImage: systemImage, color: color)
            .accessibilityLabel("采集链路：\(title)")
    }

    private var isConnected: Bool {
        switch collector {
        case .screenUnderstanding, .applicationWindowContext, .keyboardAggregates,
             .pointerAggregates, .weather:
            true
        case .chromeContext, .calendar, .reminders:
            false
        }
    }

    private var title: String { isConnected ? "链路已接通" : "等待采集器接入" }
    private var systemImage: String { isConnected ? "point.3.connected.trianglepath.dotted" : "clock.badge.exclamationmark" }
    private var color: Color { isConnected ? .green : .secondary }
}
