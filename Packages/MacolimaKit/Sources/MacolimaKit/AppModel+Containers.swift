import Foundation

public enum ContainerAction: Sendable {
    case start, stop, restart, delete
}

extension AppModel {
    static let notLiveMessage = "Docker is not available. Start Colima first."

    /// Runs one action. Never throws: the outcome carries the error text for the UI.
    public func perform(_ action: ContainerAction, on container: ContainerSummary) async -> PruneOutcome<ContainerSummary> {
        let outcome = await apply(action, to: container)
        await refreshAfterMutation()
        return outcome
    }

    /// Starts the members that are stopped. Order and `depends_on` are not reproduced.
    public func startProject(_ group: ContainerGroup) async -> [PruneOutcome<ContainerSummary>] {
        await applyToProject(.start, group.containers.filter { [.exited, .created, .dead].contains($0.state) })
    }

    /// Stops the members that are running.
    public func stopProject(_ group: ContainerGroup) async -> [PruneOutcome<ContainerSummary>] {
        await applyToProject(.stop, group.containers.filter { [.running, .paused, .restarting].contains($0.state) })
    }

    private func applyToProject(_ action: ContainerAction, _ members: [ContainerSummary]) async -> [PruneOutcome<ContainerSummary>] {
        var outcomes: [PruneOutcome<ContainerSummary>] = []
        for member in members { outcomes.append(await apply(action, to: member)) }
        await refreshAfterMutation()
        return outcomes
    }

    private func apply(_ action: ContainerAction, to container: ContainerSummary) async -> PruneOutcome<ContainerSummary> {
        guard canMutate, let engine else { return PruneOutcome(item: container, error: Self.notLiveMessage) }
        do {
            switch action {
            case .start: try await engine.start(container.id)
            case .stop: try await engine.stop(container.id)
            case .restart: try await engine.restart(container.id)
            case .delete: try await engine.removeContainer(container.id)   // keeps its volumes, never forced
            }
            return PruneOutcome(item: container, error: nil)
        } catch {
            return PruneOutcome(item: container, error: Pruner.describe(error))
        }
    }
}

extension AppModel {
    /// Live tail of a container's logs; TTY containers are not multiplexed, so ask the engine first.
    public func logs(for container: ContainerSummary, tail: Int = 500) -> AsyncThrowingStream<LogLine, Error> {
        guard let engine else { return AsyncThrowingStream { $0.finish(throwing: DockerError.socketMissing) } }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tty = try await engine.isTTY(containerID: container.id)
                    for try await line in engine.logs(containerID: container.id, tail: tail, tty: tty) { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
