import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }

            LogConsoleView()
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .frame(minWidth: 520, minHeight: 300)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject private var settings: SettingsStore

    private let portFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.allowsFloats = false
        f.minimum = 1
        f.maximum = 65535
        return f
    }()

    var body: some View {
        Form {
            TextField("AWS Region", text: $settings.region)
            TextField("AWS Profile", text: $settings.profile)
            TextField("Default Model ID", text: $settings.defaultModel)
            TextField("Local Port", value: $settings.port, formatter: portFormatter)
        }
        .formStyle(.grouped)
        .padding()
    }
}
