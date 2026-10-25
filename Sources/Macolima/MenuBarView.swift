import SwiftUI
import MacolimaKit

/// The menubar icon: a box plus the number of containers that are up. Count is hidden while data is not live.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.connection == .live {
            Label("\(model.menuBarSummary.activeCount)", systemImage: "shippingbox.fill")
        } else {
            Label("Docker unavailable", systemImage: "shippingbox")
        }
    }
}

/// Popup behind the menubar icon: running containers with stop, a few stopped ones with start.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var busy: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    @ViewBuilder private var content: some View {
        if model.connection == .live {
            let summary = model.menuBarSummary
            section(summary.activeCount == 0 ? "No containers running" : "\(summary.activeCount) running")
            ForEach(summary.active) { row($0, symbol: "stop.fill", help: "Stop", action: .stop) }
            if !summary.stopped.isEmpty {
                Divider().padding(.vertical, 4)
                section("Stopped")
                ForEach(summary.stopped) { row($0, symbol: "play.fill", help: "Start", action: .start) }
                if summary.hiddenStoppedCount > 0 {
                    Text("and \(summary.hiddenStoppedCount) more in Macolima")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 4)
                }
            }
        } else {
            offline
        }
    }

    private var offline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(offlineText).font(.callout).foregroundStyle(.secondary)
            if case .colimaStopped = model.connection, !model.colimaMissing {
                Button("Start Colima") { Task { await model.startColima() } }
                    .disabled(model.colimaBusy)
            } else {
                Button("Retry") { Task { await model.reconnect() } }
            }
        }
        .padding(12)
    }

    private var offlineText: String {
        if model.colimaMissing { return "Colima is not installed." }
        switch model.connection {
        case .live: return ""
        case .colimaStopped: return "Colima is stopped."
        case .stale: return "Docker is not responding."
        case .unreachable(let message): return message
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.headline).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ container: ContainerSummary, symbol: String, help: String, action: ContainerAction) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).lineLimit(1)
                Text(container.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                run(action, on: container)
            } label: {
                Label(help, systemImage: symbol).labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(help)
            .disabled(busy.contains(container.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button("Open Macolima") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private func run(_ action: ContainerAction, on container: ContainerSummary) {
        busy.insert(container.id)
        error = nil
        Task {
            let outcome = await model.perform(action, on: container)
            error = outcome.error
            busy.remove(container.id)
        }
    }
}
