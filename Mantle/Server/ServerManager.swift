import Foundation
import SwiftUI

@MainActor final class ServerManager: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var statusMessage: String = "Stopped"

    var iconName: String { isRunning ? "circle.fill" : "circle" }

    private var server: ProxyServer?
    private let settings = SettingsStore()

    func toggle() async {
        if isRunning {
            await server?.stop()
            server = nil
            isRunning = false
            statusMessage = "Stopped"
            log(.info, "Server stopped")
        } else {
            let proxy = ProxyServer(settings: settings)
            server = proxy
            log(.info, "Starting server on port \(settings.port)…")
            do {
                try await proxy.start()
                isRunning = true
                statusMessage = "Running on port \(settings.port)"
                log(.info, "Server listening on 127.0.0.1:\(settings.port)")
            } catch ProxyError.portInUse(let p) {
                server = nil
                isRunning = false
                statusMessage = "Error: port \(p) in use"
                log(.error, "Port \(p) is already in use")
            } catch {
                server = nil
                isRunning = false
                statusMessage = "Error: \(error.localizedDescription)"
                log(.error, "Server failed to start: \(error.localizedDescription)")
            }
        }
    }

    private func log(_ level: LogLevel, _ text: String) {
        Task {
            await LogStore.shared.append(LogEntry(date: Date(), level: level, text: text))
        }
    }
}
