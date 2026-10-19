import Foundation

public struct PrunePlan<Item> {
    public let items: [Item]
    /// Sum of the sizes that are known; items of unknown size are counted separately, never as 0 bytes.
    public let knownBytes: Int64
    public let unknownSizeCount: Int

    public init(items: [Item], knownBytes: Int64, unknownSizeCount: Int) {
        self.items = items
        self.knownBytes = knownBytes
        self.unknownSizeCount = unknownSizeCount
    }
}

extension PrunePlan: Sendable where Item: Sendable {}

public enum PrunePlanner {
    public static func unusedImages(_ images: [ImageSummary], usage: UsageIndex) -> PrunePlan<ImageSummary> {
        let items = images.filter(usage.isUnused).sorted { $0.size > $1.size }
        return PrunePlan(items: items, knownBytes: items.reduce(0) { $0 + $1.size }, unknownSizeCount: 0)
    }

    public static func unusedVolumes(_ volumes: [VolumeSummary], usage: UsageIndex) -> PrunePlan<VolumeSummary> {
        let items = volumes.filter(usage.isUnused).sorted {
            switch ($0.size, $1.size) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            default: return false
            }
        }
        return PrunePlan(items: items,
                         knownBytes: items.compactMap(\.size).reduce(0, +),
                         unknownSizeCount: items.filter { $0.size == nil }.count)
    }
}

public struct PruneOutcome<Item> {
    public let item: Item
    public let error: String?

    public init(item: Item, error: String?) {
        self.item = item
        self.error = error
    }
}

extension PruneOutcome: Sendable where Item: Sendable {}

public enum Pruner {
    /// Removes item by item; a failure is recorded for that item and the rest are still processed.
    public static func run<Item>(_ plan: PrunePlan<Item>, remove: (Item) async throws -> Void) async -> [PruneOutcome<Item>] {
        var outcomes: [PruneOutcome<Item>] = []
        for item in plan.items {
            do {
                try await remove(item)
                outcomes.append(PruneOutcome(item: item, error: nil))
            } catch {
                outcomes.append(PruneOutcome(item: item, error: describe(error)))
            }
        }
        return outcomes
    }

    /// Human-readable text for an error from the engine, Colima or the shell.
    public static func describe(_ error: Error) -> String {
        switch error as? DockerError {
        case .http(_, let message): return message
        case .socketMissing: return "Docker socket not found"
        case .connectionRefused: return "Docker is not responding"
        case .timedOut: return "Docker did not answer in time. The Colima VM may be stuck; try restarting Colima."
        case .decoding(let detail): return detail
        case nil: return error.localizedDescription
        }
    }
}

public enum PruneSummary {
    /// One line under the preview list. Image sizes include layers shared with other images, so a summed image
    /// total is an upper bound ("up to"); unknown sizes are listed apart and never counted as 0 bytes.
    public static func text(count: Int, knownBytes: Int64, unknownSizeCount: Int, sizesAreShared: Bool) -> String {
        let size = ByteCountFormatter.string(fromByteCount: knownBytes, countStyle: .file)
        var text = "\(count) item\(count == 1 ? "" : "s") · frees " + (sizesAreShared ? "up to " : "") + size
        if unknownSizeCount > 0 { text += " + \(unknownSizeCount) item\(unknownSizeCount == 1 ? "" : "s") of unknown size" }
        text += " inside the VM"
        if sizesAreShared { text += " (layers shared between images are counted once per image)" }
        return text
    }
}

extension PrunePlan {
    public func summary(sizesAreShared: Bool = false) -> String {
        PruneSummary.text(count: items.count, knownBytes: knownBytes, unknownSizeCount: unknownSizeCount, sizesAreShared: sizesAreShared)
    }
}
