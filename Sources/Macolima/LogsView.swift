import SwiftUI
import AppKit
import MacolimaKit

/// Batches incoming lines so a chatty container does not re-render the view per line.
@MainActor @Observable
final class LogModel {
    private(set) var lines: [LogLine] = []
    private(set) var error: String?
    @ObservationIgnored private var buffer = LogBuffer(capacity: 5000)
    @ObservationIgnored private var pending: [LogLine] = []

    func run(_ stream: AsyncThrowingStream<LogLine, Error>) async {
        let flusher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                self?.flush()
            }
        }
        defer { flusher.cancel(); flush() }
        do {
            for try await line in stream { pending.append(line) }
        } catch {
            if !Task.isCancelled { self.error = Pruner.describe(error) }
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        buffer.append(pending)
        pending.removeAll()
        lines = buffer.lines
    }

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let container: ContainerSummary
    @State private var logs = LogModel()
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs · \(container.name)").font(.headline)
                Spacer()
                Toggle("Auto-scroll", isOn: $follow).toggleStyle(.checkbox)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logs.text, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(logs.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.stream == .stderr ? Color.red : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                }
                .onChange(of: logs.lines.count) { _, _ in
                    if follow { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if let error = logs.error {
                Divider()
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .frame(minWidth: 700, minHeight: 440)
        .task { await logs.run(model.logs(for: container)) }
    }
}
