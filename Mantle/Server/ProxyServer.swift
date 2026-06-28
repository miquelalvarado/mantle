import Foundation
import Hummingbird
import NIOCore
import NIOPosix

enum ProxyError: LocalizedError {
    case portInUse(Int)

    var errorDescription: String? {
        switch self {
        case .portInUse(let p): return "Port \(p) is already in use"
        }
    }
}

actor ProxyServer {
    private var runningTask: Task<Void, Error>?
    private let settings: SettingsStore
    private let bedrock = BedrockService()

    var isRunning: Bool { runningTask != nil }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() async throws {
        guard runningTask == nil else { return }

        let port = await MainActor.run { settings.port }
        let chatHandler = ChatHandler(settings: settings, bedrock: bedrock)

        let router = Router()
        ModelsHandler.register(on: router)
        chatHandler.register(on: router)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )

        // Keep a reference to the error channel so we can surface bind failures.
        let errorBox = ErrorBox()

        let task = Task<Void, Error> {
            do {
                try await app.runService()
            } catch {
                let mapped = Self.mapBindError(error, port: port)
                await errorBox.set(mapped)
                throw mapped
            }
        }

        // Give the server enough time to either bind successfully or fail fast.
        try await Task.sleep(for: .milliseconds(300))

        if let bindError = await errorBox.get() {
            task.cancel()
            throw bindError
        }

        runningTask = task
    }

    func stop() async {
        runningTask?.cancel()
        runningTask = nil
    }

    private static func mapBindError(_ error: Error, port: Int) -> Error {
        let desc = "\(error)"
        if desc.contains("EADDRINUSE") || desc.contains("address already in use") {
            return ProxyError.portInUse(port)
        }
        return error
    }
}

private actor ErrorBox {
    private var error: Error?
    func set(_ e: Error) { error = e }
    func get() -> Error? { error }
}
