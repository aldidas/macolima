import SwiftUI
import MacolimaKit

enum VolumeFormat {
    static func size(_ volume: VolumeSummary) -> String { volume.size.map(Bytes.string) ?? "—" }
}

struct VolumesView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<String>
    @State private var sortOrder = [KeyPathComparator(\VolumeSummary.sortSize, order: .reverse)]
    @State private var request: PruneRequest?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: "externaldrive",
                                       description: Text("Volumes created by docker or docker compose appear here."))
            } else {
                Table(VolumeOrdering.unknownLast(model.volumes.sorted(using: sortOrder)), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Volume", value: \.name) { Text($0.name).lineLimit(1) }
                    TableColumn("Size", value: \.sortSize) { Text(VolumeFormat.size($0)).monospacedDigit() }
                        .width(min: 70, ideal: 80)
                    TableColumn("Used by") { volume in
                        let holders = model.usage.containersUsing(volume: volume)
                        if holders.isEmpty {
                            Text("Unused").foregroundStyle(.green)
                        } else {
                            Text(holders.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .pruneSheet($request)
    }

    private var selectedVolumes: [VolumeSummary] { model.volumes.filter { selection.contains($0.id) } }

    private var toolbar: some View {
        HStack {
            Button("Delete Selected…") { confirmDelete(selectedVolumes) }
                .disabled(!model.canMutate || selectedVolumes.isEmpty)
            Spacer()
            Button("Remove all unused…") { confirmPrune() }
                .disabled(!model.canMutate || model.unusedVolumesPlan.items.isEmpty)
        }
        .padding(10)
    }

    private func entry(_ volume: VolumeSummary) -> PruneEntry {
        let holders = model.usage.containersUsing(volume: volume).map(\.name)
        let used = holders.isEmpty ? "" : " · used by " + holders.joined(separator: ", ")
        return PruneEntry(id: volume.id, label: volume.name, detail: VolumeFormat.size(volume) + used)
    }

    private func results(_ outcomes: [PruneOutcome<VolumeSummary>]) -> [PruneSheet.Result] {
        outcomes.map { ($0.item.name, $0.error) }
    }

    private func confirmDelete(_ volumes: [VolumeSummary]) {
        let known = volumes.compactMap(\.size).reduce(0, +)
        let inUse = volumes.filter { !model.usage.isUnused($0) }
        request = PruneRequest(
            title: "Delete \(volumes.count) volume\(volumes.count == 1 ? "" : "s")?",
            entries: volumes.map(entry),
            knownBytes: known, unknownSizeCount: volumes.filter { $0.size == nil }.count,
            warning: "The data in " + (volumes.count == 1 ? "this volume" : "these volumes") + " is deleted permanently."
                + (inUse.isEmpty ? "" : " \(inUse.count) still referenced by a container; Docker will refuse those."),
            confirmLabel: "Delete",
            run: { results(await model.deleteVolumes(volumes)) })
    }

    private func confirmPrune() {
        let plan = model.unusedVolumesPlan
        request = PruneRequest(
            title: "Remove all unused volumes?",
            entries: plan.items.map(entry), knownBytes: plan.knownBytes, unknownSizeCount: plan.unknownSizeCount,
            warning: "Volumes hold data (databases, uploads). Removing them deletes that data permanently, and it cannot be undone.",
            run: { results(await model.pruneUnusedVolumes()) })
    }
}

private extension VolumeSummary {
    /// Sort key for the table; `VolumeOrdering.unknownLast` then keeps unknown sizes at the end.
    var sortSize: Int64 { size ?? -1 }
}

struct VolumeDetailView: View {
    @Environment(AppModel.self) private var model
    let selection: Set<String>

    var body: some View {
        let volumes = model.volumes.filter { selection.contains($0.id) }
        if volumes.count == 1, let volume = volumes.first {
            single(volume)
        } else if volumes.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(volumes.count) volumes selected").font(.title2.bold())
                Text(Bytes.string(volumes.compactMap(\.size).reduce(0, +)) + " known size"
                     + (volumes.contains { $0.size == nil } ? " + volumes of unknown size" : ""))
                    .foregroundStyle(.secondary)
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("No Volume Selected", systemImage: "externaldrive")
        }
    }

    private func single(_ volume: VolumeSummary) -> some View {
        let holders = model.usage.containersUsing(volume: volume)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(volume.name).font(.title2.bold())
                if holders.isEmpty {
                    Label("Unused: no container, running or stopped, references this volume.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Label("Used by " + holders.map { "“\($0.name)”" }.joined(separator: ", ") + ".", systemImage: "lock.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("Size", volume.size == nil ? "Unknown (not computed by Docker)" : VolumeFormat.size(volume))
                    row("Driver", volume.driver)
                    row("Mountpoint", volume.mountpoint)
                    if let created = volume.createdAt { row("Created", created.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
