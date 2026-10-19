import Foundation

public enum VolumeOrdering {
    /// Moves volumes whose size the engine has not computed to the end, keeping the order of the rest,
    /// whichever direction the list is sorted in.
    public static func unknownLast(_ volumes: [VolumeSummary]) -> [VolumeSummary] {
        volumes.filter { $0.size != nil } + volumes.filter { $0.size == nil }
    }
}

extension AppModel {
    /// What "Remove all unused…" would remove right now (the preview sheet shows exactly this).
    public var unusedVolumesPlan: PrunePlan<VolumeSummary> {
        PrunePlanner.unusedVolumes(volumes, usage: usage)
    }

    /// Deletes the given volumes, never forced. A volume a container still references is refused by the
    /// engine and reported per item; one failure never stops the rest.
    public func deleteVolumes(_ volumes: [VolumeSummary]) async -> [PruneOutcome<VolumeSummary>] {
        guard canMutate, let engine else { return volumes.map { PruneOutcome(item: $0, error: Self.notLiveMessage) } }
        let plan = PrunePlan(items: volumes, knownBytes: 0, unknownSizeCount: 0)
        let outcomes = await Pruner.run(plan) { try await engine.removeVolume($0.name) }
        await refreshAfterMutation()
        return outcomes
    }

    /// Removes exactly the previewed plan. It never recomputes "unused" at confirm time: volumes hold data, so what
    /// the user was shown is all that may go.
    public func pruneUnused(_ plan: PrunePlan<VolumeSummary>) async -> [PruneOutcome<VolumeSummary>] {
        await deleteVolumes(plan.items)
    }
}
