import Darwin
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

        // Probe port availability immediately — avoids racing against NIO's slower bind error.
        try Self.checkPortAvailable(port)

        let chatHandler = ChatHandler(settings: settings, bedrock: bedrock)

        let router = Router()
        ModelsHandler.register(on: router)
        chatHandler.register(on: router)

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )

        let task = Task<Void, Error> {
            try await app.runService()
        }

        // Give Hummingbird a moment to bind, then store the task.
        try await Task.sleep(for: .milliseconds(300))
        runningTask = task
    }

    private static func checkPortAvailable(_ port: Int) throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        defer { close(sock) }
        // Non-blocking connect to 127.0.0.1:port.
        // If something is already listening, connect will succeed quickly.
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(UInt16(port))
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let connectErrno = errno
        if connectResult == 0 {
            // Immediate success — port is in use
            throw ProxyError.portInUse(port)
        }
        if connectErrno == EINPROGRESS {
            // Use poll to wait up to 200ms for the connection to complete
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pfd, 1, 200)
            if pollResult > 0 {
                // Check SO_ERROR — if 0, connection succeeded (port in use)
                var err: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &errLen)
                if err == 0 {
                    throw ProxyError.portInUse(port)
                }
            }
        }
        // ECONNREFUSED or timeout → port is free
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

// Actor that carries a single optional Error result from the server task.
private actor StartupChannel {
    private var error: Error?
    private var waiters: [CheckedContinuation<Error?, Never>] = []
    private var resolved = false

    func fail(_ error: Error) {
        guard !resolved else { return }
        resolved = true
        self.error = error
        for cont in waiters { cont.resume(returning: error) }
        waiters.removeAll()
    }

    // Returns the bind error if one arrives within `timeout`, or nil on timeout.
    func waitWithTimeout(_ timeout: Duration) async -> Error? {
        if resolved { return error }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            Task {
                try? await Task.sleep(for: timeout)
                // Resume with nil (timeout = success) if not yet resolved.
                self.timeoutFired(cont)
            }
        }
    }

    private func timeoutFired(_ cont: CheckedContinuation<Error?, Never>) {
        guard !resolved else { return }
        resolved = true
        cont.resume(returning: nil)
    }
}
