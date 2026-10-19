import SwiftUI
import MacolimaKit

/// One thing a delete or prune will remove, listed exactly in the preview.
struct PruneEntry: Identifiable {
    let id: String
    let label: String
    let detail: String
}

/// Preview, then run, then per-item results. Nothing is removed until "Remove" is pressed.
struct PruneSheet: View {
    typealias Result = (label: String, error: String?)

    let title: String
    let entries: [PruneEntry]
    let summary: String
    var warning: String?
    var confirmLabel = "Remove"
    let run: () async -> [Result]

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.preview

    private enum Phase { case preview, running, done([Result]) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            switch phase {
            case .preview: preview
            case .running:
                ProgressView("Removing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .done(let results): done(results)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            List(entries) { entry in
                HStack {
                    Text(entry.label).lineLimit(1)
                    Spacer()
                    Text(entry.detail).foregroundStyle(.secondary).font(.caption)
                }
            }
            Text(summary).font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmLabel, role: .destructive) {
                    phase = .running
                    Task { phase = .done(await run()) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entries.isEmpty)
            }
        }
    }

    private func done(_ results: [Result]) -> some View {
        let failures = results.filter { $0.error != nil }
        return VStack(alignment: .leading, spacing: 12) {
            Text(failures.isEmpty ? "Removed \(results.count) item\(results.count == 1 ? "" : "s")."
                                  : "Removed \(results.count - failures.count) of \(results.count). \(failures.count) failed:")
                .font(.callout)
            if !failures.isEmpty {
                List(failures.indices, id: \.self) { i in
                    VStack(alignment: .leading) {
                        Text(failures[i].label).font(.body.weight(.medium))
                        Text(failures[i].error ?? "").font(.caption).foregroundStyle(.red)
                    }
                }
            } else {
                Spacer()
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
    }
}

/// What the Images and Volumes views ask the sheet to show.
struct PruneRequest: Identifiable {
    let id = UUID()
    let title: String
    let entries: [PruneEntry]
    let summary: String
    var warning: String?
    var confirmLabel = "Remove"
    let run: () async -> [PruneSheet.Result]
}

extension View {
    func pruneSheet(_ request: Binding<PruneRequest?>) -> some View {
        sheet(item: request) { r in
            PruneSheet(title: r.title, entries: r.entries, summary: r.summary,
                       warning: r.warning, confirmLabel: r.confirmLabel, run: r.run)
        }
    }
}
