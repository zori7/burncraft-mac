import BurnCore
import SwiftUI

@main
struct MainApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 620)
                .task { model.startDriveMonitoring() }
        }
        .windowResizability(.contentMinSize)
    }
}
