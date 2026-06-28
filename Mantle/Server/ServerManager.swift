import Foundation
import SwiftUI

@MainActor final class ServerManager: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var statusMessage: String = "Stopped"

    var iconName: String { isRunning ? "circle.fill" : "circle" }

    private var server: ProxyServer?
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func toggle() async {
        if isRunning {
            await server?.stop()
            server = nil
            isRunning = false
            statusMessage = "Stopped"
        } else {
            let proxy = ProxyServer(settings: settings)
            server = proxy
            do {
                try await proxy.start()
                isRunning = true
                statusMessage = "Running on port \(settings.port)"
            } catch ProxyError.portInUse(let p) {
                server = nil
                isRunning = false
                statusMessage = "Error: port \(p) in use"
            } catch {
                server = nil
                isRunning = false
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }
}
