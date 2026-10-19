import SwiftUI

@main
struct DaydayHealthCompanionApp: App {
    @StateObject private var model = HealthCompanionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HealthCompanionRootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.resumePendingSyncWhenActive()
        }
    }
}
