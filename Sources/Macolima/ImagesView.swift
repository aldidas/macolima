import SwiftUI
import MacolimaKit

enum ImageFormat {
    static func name(_ image: ImageSummary) -> String { image.tags.first ?? "<none>" }
    static func shortID(_ image: ImageSummary) -> String { String(image.id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
}

struct ImagesView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<String>
    @State private var sortOrder = [KeyPathComparator(\ImageSummary.size, order: .reverse)]
    @State private var request: PruneRequest?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.images.isEmpty {
                ContentUnavailableView("No Images", systemImage: "square.stack.3d.up",
                                       description: Text("Images you pull or build with docker appear here."))
            } else {
                Table(model.images.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Image", value: \.sortName) { image in
                        Text(ImageFormat.name(image)).foregroundStyle(image.tags.isEmpty ? .secondary : .primary)
                    }
                    TableColumn("Size", value: \.size) { Text(Bytes.string($0.size)).monospacedDigit() }
                        .width(min: 70, ideal: 80)
                    TableColumn("Created", value: \.created) { Text($0.created.formatted(date: .abbreviated, time: .omitted)) }
                        .width(min: 90, ideal: 110)
                    TableColumn("Used by") { image in
                        let holders = model.usage.containersUsing(image: image)
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

    private var selectedImages: [ImageSummary] { model.images.filter { selection.contains($0.id) } }

    private var toolbar: some View {
        HStack {
            Button("Delete Selected…") { confirmDelete(selectedImages) }
                .disabled(!model.canMutate || deletableSelection.isEmpty)
                .help(deleteHelp)
            Spacer()
            Button("Remove all unused…") { confirmPrune() }
                .disabled(!model.canMutate || model.unusedImagesPlan.items.isEmpty)
        }
        .padding(10)
    }

    private var deletableSelection: [ImageSummary] { selectedImages.filter { model.usage.isUnused($0) } }

    private var deleteHelp: String {
        let blocked = selectedImages.count - deletableSelection.count
        return blocked > 0 ? "\(blocked) selected image(s) are used by a container and cannot be deleted." : "Delete the selected images"
    }

    private func entries(_ images: [ImageSummary]) -> [PruneEntry] {
        images.map { PruneEntry(id: $0.id, label: $0.tags.isEmpty ? "<none> (\(ImageFormat.shortID($0)))" : $0.tags.joined(separator: ", "), detail: Bytes.string($0.size)) }
    }

    private func results(_ outcomes: [PruneOutcome<ImageSummary>]) -> [PruneSheet.Result] {
        outcomes.map { (ImageFormat.name($0.item), $0.error) }
    }

    private func confirmDelete(_ images: [ImageSummary]) {
        let deletable = images.filter { model.usage.isUnused($0) }
        let skipped = images.count - deletable.count
        request = PruneRequest(
            title: "Delete \(deletable.count) image\(deletable.count == 1 ? "" : "s")?",
            entries: entries(deletable),
            knownBytes: deletable.reduce(0) { $0 + $1.size }, unknownSizeCount: 0,
            warning: skipped > 0 ? "\(skipped) selected image(s) are used by a container and will be skipped." : nil,
            confirmLabel: "Delete",
            run: { results(await model.deleteImages(deletable)) })
    }

    private func confirmPrune() {
        let plan = model.unusedImagesPlan
        request = PruneRequest(
            title: "Remove all unused images?",
            entries: entries(plan.items), knownBytes: plan.knownBytes, unknownSizeCount: plan.unknownSizeCount,
            warning: nil,
            run: { results(await model.pruneUnused(plan)) })
    }
}

private extension ImageSummary {
    var sortName: String { tags.first ?? "~" }
}

struct ImageDetailView: View {
    @Environment(AppModel.self) private var model
    let selection: Set<String>

    var body: some View {
        let images = model.images.filter { selection.contains($0.id) }
        if images.count == 1, let image = images.first {
            single(image)
        } else if images.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(images.count) images selected").font(.title2.bold())
                Text(Bytes.string(images.reduce(0) { $0 + $1.size }) + " in total")
                    .foregroundStyle(.secondary)
                Text("\(images.filter { !model.usage.isUnused($0) }.count) in use by containers")
                    .foregroundStyle(.secondary)
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("No Image Selected", systemImage: "square.stack.3d.up")
        }
    }

    private func single(_ image: ImageSummary) -> some View {
        let holders = model.usage.containersUsing(image: image)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(ImageFormat.name(image)).font(.title2.bold())
                if holders.isEmpty {
                    Label("Unused: no container, running or stopped, references this image.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Label("In use by " + holders.map { "“\($0.name)”" }.joined(separator: ", ") + ". It cannot be deleted while any container references it.",
                          systemImage: "lock.fill").foregroundStyle(.orange).font(.callout)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    row("Size", Bytes.string(image.size))
                    row("ID", ImageFormat.shortID(image))
                    row("Created", image.created.formatted(date: .abbreviated, time: .shortened))
                    if image.tags.isEmpty { row("Tags", "none (dangling)") } else { row("Tags", image.tags.joined(separator: "\n")) }
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
