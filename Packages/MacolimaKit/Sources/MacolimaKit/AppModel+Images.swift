import Foundation

extension AppModel {
    /// What "Remove all unused…" would remove right now (the preview sheet shows exactly this).
    public var unusedImagesPlan: PrunePlan<ImageSummary> {
        PrunePlanner.unusedImages(images, usage: usage)
    }

    /// Deletes the given images, never forced. Images any container (running or stopped) references are
    /// not sent to the engine; they come back with an error naming the holder. One failure never stops the rest.
    public func deleteImages(_ images: [ImageSummary]) async -> [PruneOutcome<ImageSummary>] {
        guard canMutate, let engine else { return images.map { PruneOutcome(item: $0, error: Self.notLiveMessage) } }
        let usage = self.usage
        var blocked: [String: String] = [:]
        for image in images {
            let holders = usage.containersUsing(image: image)
            if !holders.isEmpty {
                blocked[image.id] = "In use by container " + holders.map { "“\($0.name)”" }.joined(separator: ", ")
            }
        }
        let removable = PrunePlan(items: images.filter { blocked[$0.id] == nil }, knownBytes: 0, unknownSizeCount: 0)
        let ran = await Pruner.run(removable) { try await Self.remove($0, using: engine) }
        await refreshAfterMutation()
        let results = Dictionary(ran.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        return images.map { image in
            results[image.id] ?? PruneOutcome(item: image, error: blocked[image.id])
        }
    }

    /// dockerd refuses `DELETE /images/<id>` without force when the image carries several tags, so such an image
    /// is untagged tag by tag (the image goes with its last tag). Single-tag and dangling images go by ID.
    private static func remove(_ image: ImageSummary, using engine: DockerEngine) async throws {
        if image.tags.count > 1 {
            for tag in image.tags { try await engine.removeImage(tag) }
        } else {
            try await engine.removeImage(image.id)
        }
    }

    /// Removes exactly the previewed plan. It never recomputes "unused" at confirm time: what the user was shown
    /// is what goes (images that gained a container since are skipped with an error, not removed).
    public func pruneUnused(_ plan: PrunePlan<ImageSummary>) async -> [PruneOutcome<ImageSummary>] {
        await deleteImages(plan.items)
    }
}
