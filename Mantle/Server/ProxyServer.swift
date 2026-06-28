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

        let signal = StartupSignal()

        let task = Task<Void, Error> {
            do {
                await signal.markStarted()
                try await app.runService()
            } catch {
                let mapped = Self.mapBindError(error, port: port)
                await signal.markFailed(mapped)
                throw mapped
            }
        }
        runningTask = task

        // Race between a short timeout (assume success) and an early error
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Wait up to 400 ms; if no error by then, consider startup successful
                try await Task.sleep(for: .milliseconds(400))
            }
            group.addTask {
                // Wait for signal from the server task
                try await signal.waitForResult()
            }
            // Take whichever finishes first
            try await group.next()
            group.cancelAll()
        }

        // If the server task already completed with an error, propagate it
        if await signal.failed {
            runningTask = nil
            throw await signal.error!
        }
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

private actor StartupSignal {
    private var state: State = .pending
    private var waiters: [CheckedContinuation<Void, Error>] = []

    enum State {
        case pending
        case started
        case failed(Error)
    }

    var failed: Bool {
        if case .failed = state { return true }
        return false
    }

    var error: Error? {
        if case .failed(let e) = state { return e }
        return nil
    }

    func markStarted() {
        guard case .pending = state else { return }
        state = .started
        // Don't resume waiters — let timeout handle success path
    }

    func markFailed(_ error: Error) {
        guard case .pending = state else { return }
        state = .failed(error)
        for cont in waiters { cont.resume(throwing: error) }
        waiters.removeAll()
    }

    func waitForResult() async throws {
        if case .failed(let e) = state { throw e }
        // Otherwise park until markFailed is called (or caller cancels via timeout)
        try await withCheckedThrowingContinuation { cont in
            waiters.append(cont)
        }
    }
}
