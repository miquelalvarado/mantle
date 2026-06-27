import SwiftUI

@main
struct MantleApp: App {
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        MenuBarExtra("Mantle", systemImage: "circle") {
            Text("Mantle")
                .padding()
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
