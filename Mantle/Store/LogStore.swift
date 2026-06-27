import Foundation

enum LogLevel: String, Sendable {
    case info, warn, error
}

struct LogEntry: Identifiable, Sendable {
    let id    = UUID()
    let date  : Date
    let level : LogLevel
    let text  : String
}

actor LogStore {
    static let shared = LogStore()

    private(set) var entries: [LogEntry] = []
    private let cap = 200

    private init() {}

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
