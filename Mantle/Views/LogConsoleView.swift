import SwiftUI

@MainActor final class LogStoreBridge: ObservableObject {
    @Published var entries: [LogEntry] = []

    private var pollingTask: Task<Void, Never>?

    init() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let current = await LogStore.shared.entries
                await MainActor.run {
                    self?.entries = current
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }
}

struct LogConsoleView: View {
    @StateObject private var bridge = LogStoreBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    Task { await LogStore.shared.clear() }
                }
                .buttonStyle(.borderless)
            }
            .padding([.horizontal, .top])

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(bridge.entries) { entry in
                            Text("[\(entry.level.rawValue.uppercased())] \(entry.text)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
                .onChange(of: bridge.entries.count) { _, _ in
                    if let last = bridge.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 200)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}
