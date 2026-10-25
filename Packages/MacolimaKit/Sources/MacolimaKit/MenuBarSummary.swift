import Foundation

/// What the menubar popup lists: the containers that are up, and a short list of the ones that can be started.
public struct MenuBarSummary: Sendable, Equatable {
    /// Running, paused or restarting; the same set "stop project" acts on.
    public let active: [ContainerSummary]
    /// Exited, created or dead, capped at the limit.
    public let stopped: [ContainerSummary]
    /// Stopped containers beyond the cap.
    public let hiddenStoppedCount: Int

    public var activeCount: Int { active.count }

    public init(containers: [ContainerSummary], stoppedLimit: Int = 5) {
        let byName: (ContainerSummary, ContainerSummary) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        active = containers.filter { [.running, .paused, .restarting].contains($0.state) }.sorted(by: byName)
        let allStopped = containers.filter { [.exited, .created, .dead].contains($0.state) }.sorted(by: byName)
        stopped = Array(allStopped.prefix(stoppedLimit))
        hiddenStoppedCount = allStopped.count - stopped.count
    }
}

extension AppModel {
    public var menuBarSummary: MenuBarSummary { MenuBarSummary(containers: containers) }
}
