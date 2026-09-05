import SwiftUI

@main
struct DashiApp: App {
    @StateObject private var store = DashboardStore()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(store) }
            .commands { CheckForUpdatesCommands(updater: updater) }
        Settings { SourceSettings().environmentObject(store) }
    }
}
