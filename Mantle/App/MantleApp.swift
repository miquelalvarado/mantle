import SwiftUI

@main
struct MantleApp: App {
    @StateObject private var settings  = SettingsStore()
    @StateObject private var serverMgr = ServerManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(settings)
                .environmentObject(serverMgr)
        } label: {
            if NSImage(named: "MenuBarIcon") != nil {
                Image("MenuBarIcon")
            } else {
                Image(systemName: serverMgr.iconName)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
