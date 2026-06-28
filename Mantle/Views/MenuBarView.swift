import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var serverMgr: ServerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(statusText)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .disabled(true)

            Divider()

            Button(serverMgr.isRunning ? "Stop Server" : "Start Server") {
                Task { await serverMgr.toggle() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .buttonStyle(.plain)

            Divider()

            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .buttonStyle(.plain)

            Divider()

            Button("Quit Mantle") {
                NSApp.terminate(nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .buttonStyle(.plain)
        }
        .frame(minWidth: 200)
    }

    private var statusText: String {
        if serverMgr.statusMessage.hasPrefix("Error:") {
            return serverMgr.statusMessage
        }
        return serverMgr.isRunning
            ? "Running on port \(settings.port)"
            : "Stopped"
    }
}
