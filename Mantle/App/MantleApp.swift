import SwiftUI

@main
struct MantleApp: App {
    @StateObject private var settings  = SettingsStore()
    @StateObject private var serverMgr = ServerManager()

    var body: some Scene {
        MenuBarExtra("Mantle", systemImage: serverMgr.iconName) {
            MenuBarView()
                .environmentObject(settings)
                .environmentObject(serverMgr)
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
