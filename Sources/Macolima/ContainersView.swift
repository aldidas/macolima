import SwiftUI
import MacolimaKit

/// Per-item results of an action, shown when anything failed.
struct ActionReport: Identifiable {
    let id = UUID()
    let title: String
    let failures: [String]

    init?(title: String, outcomes: [PruneOutcome<ContainerSummary>]) {
        let failures = outcomes.compactMap { o in o.error.map { "\(o.item.name): \($0)" } }
        guard !failures.isEmpty else { return nil }
        self.title = title
        self.failures = failures
    }
}

extension View {
    func actionReport(_ report: Binding<ActionReport?>) -> some View {
        alert(report.wrappedValue?.title ?? "", isPresented: Binding(get: { report.wrappedValue != nil }, set: { if !$0 { report.wrappedValue = nil } })) {
            Button("OK") {}
        } message: {
            Text(report.wrappedValue?.failures.joined(separator: "\n") ?? "")
        }
    }
}

enum ContainerFormat {
    static func color(_ state: ContainerState) -> Color {
        switch state {
        case .running: .green
        case .paused: .yellow
        case .restarting: .orange
        default: .secondary
        }
    }

    static func ports(_ ports: [PortMapping]) -> String {
        ports.map { p in p.publicPort.map { "\($0)→\(p.privatePort)/\(p.type)" } ?? "\(p.privatePort)/\(p.type)" }.joined(separator: ", ")
    }
}

struct ContainersView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @State private var report: ActionReport?

    var body: some View {
        let groups = ComposeGrouping.group(model.containers)
        Group {
            if groups.isEmpty {
                ContentUnavailableView("No Containers", systemImage: "shippingbox",
                                       description: Text("Containers you create with docker or docker compose appear here."))
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.containers) { ContainerRow(container: $0).tag($0.id) }
                        } header: {
                            header(group)
                        }
                    }
                }
            }
        }
        .actionReport($report)
    }

    private func header(_ group: ContainerGroup) -> some View {
        HStack {
            Text(group.project ?? "Standalone").font(.headline)
            Text("\(group.runningCount)/\(group.containers.count) running").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if group.project != nil {
                Button("Start all") { Task { report = ActionReport(title: "Some containers failed to start", outcomes: await model.startProject(group)) } }
                    .disabled(!model.canMutate || group.runningCount == group.containers.count)
                Button("Stop all") { Task { report = ActionReport(title: "Some containers failed to stop", outcomes: await model.stopProject(group)) } }
                    .disabled(!model.canMutate || group.runningCount == 0)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

private struct ContainerRow: View {
    let container: ContainerSummary

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(ContainerFormat.color(container.state)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name).font(.body.weight(.medium))
                Text(container.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !container.ports.isEmpty {
                Text(ContainerFormat.ports(container.ports)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ContainerDetailView: View {
    @Environment(AppModel.self) private var model
    let containerID: String?
    @State private var report: ActionReport?
    @State private var confirmDelete = false
    @State private var showLogs = false

    private var container: ContainerSummary? { model.containers.first { $0.id == containerID } }

    var body: some View {
        if let container {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Circle().fill(ContainerFormat.color(container.state)).frame(width: 12, height: 12)
                        Text(container.name).font(.title2.bold())
                    }
                    actions(container)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                        row("Status", container.status)
                        row("Image", container.image)
                        row("ID", String(container.id.prefix(12)))
                        if let p = container.composeProject { row("Compose project", p) }
                        if let s = container.composeService { row("Service", s) }
                        if !container.ports.isEmpty { row("Ports", ContainerFormat.ports(container.ports)) }
                        if !container.volumeNames.isEmpty { row("Volumes", container.volumeNames.joined(separator: ", ")) }
                        row("Created", container.created.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $showLogs) { LogsView(container: container) }
            .actionReport($report)
            .confirmationDialog("Delete “\(container.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Container", role: .destructive) {
                    Task { report = ActionReport(title: "Could not delete", outcomes: [await model.perform(.delete, on: container)]) }
                }
            } message: {
                Text("The container is removed. Its volumes are kept; remove them from the Volumes view.")
            }
        } else {
            ContentUnavailableView("No Container Selected", systemImage: "shippingbox")
        }
    }

    private func actions(_ c: ContainerSummary) -> some View {
        let isRunning = [.running, .paused, .restarting].contains(c.state)
        return HStack {
            iconButton("Start", "play.fill") { run(.start, c) }.disabled(isRunning)
            iconButton("Stop", "stop.fill") { run(.stop, c) }.disabled(!isRunning)
            iconButton("Restart", "arrow.clockwise") { run(.restart, c) }.disabled(!isRunning)
            iconButton("Logs", "text.alignleft") { showLogs = true }
            Spacer()
            iconButton("Delete…", "trash", role: .destructive) { confirmDelete = true }
        }
        .disabled(!model.canMutate)
    }

    /// Icon-only button; the title stays as the accessibility label and the tooltip.
    private func iconButton(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .help(title)
    }

    private func run(_ action: ContainerAction, _ c: ContainerSummary) {
        Task { report = ActionReport(title: "Action failed", outcomes: [await model.perform(action, on: c)]) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
