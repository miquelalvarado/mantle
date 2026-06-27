import SwiftUI

@main
struct MantleApp: App {
    var body: some Scene {
        MenuBarExtra("Mantle", systemImage: "circle") {
            Text("Hello from Mantle")
                .padding()
        }
        Settings {
            EmptyView()
        }
    }
}
