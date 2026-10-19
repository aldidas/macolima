import Foundation

/// "Unused" = no container, running or stopped, references the image or volume.
public struct UsageIndex: Sendable {
    private let containers: [ContainerSummary]

    public init(containers: [ContainerSummary]) { self.containers = containers }

    public func containersUsing(image: ImageSummary) -> [ContainerSummary] {
        containers.filter { $0.imageID == image.id }
    }

    public func containersUsing(volume: VolumeSummary) -> [ContainerSummary] {
        containers.filter { $0.volumeNames.contains(volume.name) }
    }

    public func isUnused(_ image: ImageSummary) -> Bool { containersUsing(image: image).isEmpty }
    public func isUnused(_ volume: VolumeSummary) -> Bool { containersUsing(volume: volume).isEmpty }
}

public struct ContainerGroup: Identifiable, Sendable {
    public let project: String?
    public let containers: [ContainerSummary]

    public var id: String { project ?? "" }
    public var runningCount: Int { containers.filter { $0.state == .running }.count }
}

public enum ComposeGrouping {
    /// Compose projects A–Z, then the standalone group (`project == nil`) last.
    public static func group(_ containers: [ContainerSummary]) -> [ContainerGroup] {
        let byName: (ContainerSummary, ContainerSummary) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let projects = Dictionary(grouping: containers.filter { $0.composeProject != nil }, by: { $0.composeProject! })
        var groups = projects.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ContainerGroup(project: $0, containers: projects[$0]!.sorted(by: byName)) }
        let standalone = containers.filter { $0.composeProject == nil }
        if !standalone.isEmpty { groups.append(ContainerGroup(project: nil, containers: standalone.sorted(by: byName))) }
        return groups
    }
}
