import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case today
    case report
    case journal
    case history
    case health
    case insights
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "今日"
        case .report: "日报"
        case .journal: "日记"
        case .history: "历史"
        case .health: "健康"
        case .insights: "洞察"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .report: "doc.text"
        case .journal: "book.pages"
        case .history: "clock.arrow.circlepath"
        case .health: "heart.text.clipboard"
        case .insights: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

enum PrototypeData {
    static let activityHours = Array(0..<24)

    static let insightSections = InsightKind.allCases
}

enum InsightKind: String, CaseIterable, Identifiable {
    case applications
    case activity
    case keyboard
    case mouse

    var id: Self { self }

    var title: String {
        switch self {
        case .applications: "应用"
        case .activity: "活动分布"
        case .keyboard: "键盘"
        case .mouse: "鼠标"
        }
    }

    var systemImage: String {
        switch self {
        case .applications: "macwindow.on.rectangle"
        case .activity: "calendar.day.timeline.leading"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        }
    }

}

extension AppRuntimeDisplay {
    var dimensionsDescription: String {
        let logical = "\(Int(logicalWidth.rounded())) × \(Int(logicalHeight.rounded())) 点"
        var parts: [String] = []
        if let pixelWidth, let pixelHeight {
            parts.append("\(pixelWidth) × \(pixelHeight) 像素")
        }
        parts.append(logical)
        if rotationDegrees != 0 {
            parts.append("旋转 \(Int(rotationDegrees.rounded()))°")
        }
        return parts.joined(separator: " · ")
    }
}

extension AppRuntimeSnapshot {
    var displayCountDescription: String {
        switch displayInventoryState {
        case .unknown: "状态未知"
        case .unavailable: "状态不可用"
        case .available: "已连接 \(displays.count) 台"
        }
    }

    var displayDimensionsDescription: String? {
        guard displayInventoryState == .available, !displays.isEmpty else { return nil }
        return displays.map(\.dimensionsDescription).joined(separator: "；")
    }
}
