import Foundation
@testable import MacolimaKit

/// In-memory `DockerEngine` that records calls and mutates its lists like a real engine would.
final class FakeEngine: DockerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _containers: [ContainerSummary]
    private var _images: [ImageSummary]
    private var _volumes: [VolumeSummary]
    private var _calls: [String] = []
    private var failures: [String: Error] = [:]
    private var eventContinuation: AsyncThrowingStream<DockerEvent, Error>.Continuation?

    var negotiateError: Error?
    var diskBytes: Int64 = 0

    init(containers: [ContainerSummary] = [], images: [ImageSummary] = [], volumes: [VolumeSummary] = []) {
        _containers = containers
        _images = images
        _volumes = volumes
    }

    var calls: [String] { lock.withLock { _calls } }
    func count(_ call: String) -> Int { calls.filter { $0 == call }.count }
    func fail(_ call: String, with error: Error) { lock.withLock { failures[call] = error } }
    func emit(_ event: DockerEvent) { _ = lock.withLock { eventContinuation }?.yield(event) }

    private func record(_ call: String) throws {
        let failure = lock.withLock { () -> Error? in _calls.append(call); return failures[call] }
        if let failure { throw failure }
    }

    func negotiate() async throws {
        try record("negotiate")
        if let negotiateError { throw negotiateError }
    }
    func containers() async throws -> [ContainerSummary] { try record("containers"); return lock.withLock { _containers } }
    func images() async throws -> [ImageSummary] { try record("images"); return lock.withLock { _images } }
    func volumes() async throws -> [VolumeSummary] { try record("volumes"); return lock.withLock { _volumes } }
    func diskUsage() async throws -> Int64 { try record("diskUsage"); return diskBytes }

    private func setState(_ id: String, _ state: ContainerState) {
        lock.withLock {
            _containers = _containers.map { c in
                c.id == id ? ContainerSummary(id: c.id, name: c.name, image: c.image, imageID: c.imageID, state: state, status: c.status,
                                              ports: c.ports, composeProject: c.composeProject, composeService: c.composeService,
                                              volumeNames: c.volumeNames, created: c.created) : c
            }
        }
    }
    func start(_ id: String) async throws { try record("start:\(id)"); setState(id, .running) }
    func stop(_ id: String) async throws { try record("stop:\(id)"); setState(id, .exited) }
    func restart(_ id: String) async throws { try record("restart:\(id)"); setState(id, .running) }
    func removeContainer(_ id: String) async throws {
        try record("removeContainer:\(id)")
        lock.withLock { _containers.removeAll { $0.id == id } }
    }
    func removeImage(_ id: String) async throws {
        try record("removeImage:\(id)")
        lock.withLock { _images.removeAll { $0.id == id } }
    }
    func removeVolume(_ name: String) async throws {
        try record("removeVolume:\(name)")
        lock.withLock { _volumes.removeAll { $0.name == name } }
    }
    func isTTY(containerID: String) async throws -> Bool { false }
    func logs(containerID: String, tail: Int, tty: Bool) -> AsyncThrowingStream<LogLine, Error> { AsyncThrowingStream { $0.finish() } }

    func events() -> AsyncThrowingStream<DockerEvent, Error> {
        AsyncThrowingStream { c in lock.withLock { eventContinuation = c } }
    }
}

/// Stands in for the `colima` binary: `status` succeeds only while "running".
final class FakeColimaShell: @unchecked Sendable {
    private let lock = NSLock()
    private var _running: Bool
    private var _calls: [[String]] = []

    init(running: Bool) { _running = running }

    var running: Bool { lock.withLock { _running } }
    var calls: [[String]] { lock.withLock { _calls } }

    func service(profile: String, home: URL = URL(fileURLWithPath: "/nonexistent-home")) -> ColimaService {
        ColimaService(profile: profile, home: home) { [self] exe, args in
            lock.withLock { _calls.append([exe] + args) }
            switch args.first {
            case "status":
                guard running else { throw ShellError.failed(exe: exe, code: 1, stderr: "colima is not running") }
                return String(decoding: Fixture.data("colima_status"), as: UTF8.self)
            case "start": lock.withLock { _running = true }
            case "stop": lock.withLock { _running = false }
            default: break
            }
            return ""
        }
    }
}
