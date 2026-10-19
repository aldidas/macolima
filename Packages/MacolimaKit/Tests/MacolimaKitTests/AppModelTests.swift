import XCTest
@testable import MacolimaKit

@MainActor
final class AppModelTests: XCTestCase {
    private let savedAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeStore() -> SnapshotStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macolima-model-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return SnapshotStore(directory: dir)
    }

    private func makeModel(engine: FakeEngine, shell: FakeColimaShell, store: SnapshotStore,
                           debounce: Duration = .milliseconds(50)) -> AppModel {
        AppModel(locate: { SocketInfo(path: "/tmp/fake.sock", profile: "default") },
                 engineFactory: { _ in engine },
                 colimaFactory: { shell.service(profile: $0) },
                 store: store, debounce: debounce, pollInterval: nil)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private var oldSnapshot: Snapshot {
        Snapshot(savedAt: savedAt, containers: [container("old")], images: [image("sha256:old")], volumes: [volume("oldvol")])
    }

    func test_bootstrap_live_savesSnapshot() async throws {
        let engine = FakeEngine(containers: [container("web")], images: [image("sha256:a", size: 5)], volumes: [volume("v1", size: 9)])
        engine.diskBytes = 12_345
        let store = makeStore()
        let model = makeModel(engine: engine, shell: FakeColimaShell(running: true), store: store)
        await model.bootstrap()

        XCTAssertEqual(model.connection, .live)
        XCTAssertTrue(model.canMutate)
        XCTAssertEqual(model.containers.map(\.name), ["web"])
        XCTAssertEqual(model.images.map(\.id), ["sha256:a"])
        XCTAssertEqual(model.volumes.map(\.name), ["v1"])
        XCTAssertEqual(model.dockerBytes, 12_345)
        guard case .running(let info) = model.colima else { return XCTFail("colima should be running") }
        XCTAssertEqual(info.cpus, 4)

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.containers, model.containers)
        XCTAssertEqual(saved.images, model.images)
        XCTAssertEqual(saved.volumes, model.volumes)
    }

    func test_bootstrap_colimaStopped_loadsSnapshot_andDisablesMutation() async throws {
        let store = makeStore()
        try store.save(oldSnapshot)
        let engine = FakeEngine(containers: [container("live")])
        let model = makeModel(engine: engine, shell: FakeColimaShell(running: false), store: store)
        await model.bootstrap()

        XCTAssertEqual(model.connection, .colimaStopped(lastSnapshot: savedAt))
        XCTAssertFalse(model.canMutate)
        XCTAssertEqual(model.colima, .stopped)
        XCTAssertEqual(model.containers.map(\.name), ["old"])
        XCTAssertEqual(model.volumes.map(\.name), ["oldvol"])
        XCTAssertTrue(engine.calls.isEmpty, "a stopped VM must not be probed through the socket")
    }

    func test_bootstrap_colimaStopped_noSnapshot_isEmptyButNotCrashing() async {
        let model = makeModel(engine: FakeEngine(), shell: FakeColimaShell(running: false), store: makeStore())
        await model.bootstrap()
        XCTAssertEqual(model.connection, .colimaStopped(lastSnapshot: nil))
        XCTAssertTrue(model.containers.isEmpty)
    }

    func test_bootstrap_socketMissingVsRefused_giveDistinctStates() async throws {
        let store = makeStore()
        try store.save(oldSnapshot)

        let missing = FakeEngine(); missing.negotiateError = DockerError.socketMissing
        let m1 = makeModel(engine: missing, shell: FakeColimaShell(running: true), store: store)
        await m1.bootstrap()

        let refused = FakeEngine(); refused.negotiateError = DockerError.connectionRefused
        let m2 = makeModel(engine: refused, shell: FakeColimaShell(running: true), store: store)
        await m2.bootstrap()

        let stopped = makeModel(engine: FakeEngine(), shell: FakeColimaShell(running: false), store: store)
        await stopped.bootstrap()

        guard case .unreachable(let message) = m1.connection else { return XCTFail("socket missing → .unreachable, got \(m1.connection)") }
        XCTAssertTrue(message.contains("/tmp/fake.sock"), message)
        XCTAssertEqual(m2.connection, .stale(savedAt))
        XCTAssertEqual(stopped.connection, .colimaStopped(lastSnapshot: savedAt))
        for m in [m1, m2, stopped] {
            XCTAssertFalse(m.canMutate)
            XCTAssertEqual(m.containers.map(\.name), ["old"], "offline states show the snapshot")
        }
    }

    func test_bootstrap_otherEngineError_isUnreachableWithMessage() async {
        let engine = FakeEngine(); engine.negotiateError = DockerError.http(status: 403, message: "permission denied")
        let model = makeModel(engine: engine, shell: FakeColimaShell(running: true), store: makeStore())
        await model.bootstrap()
        XCTAssertEqual(model.connection, .unreachable("permission denied"))
    }

    func test_event_triggersRefresh_debounced() async {
        let engine = FakeEngine(containers: [container("web")])
        let model = makeModel(engine: engine, shell: FakeColimaShell(running: true), store: makeStore(), debounce: .milliseconds(150))
        await model.bootstrap()
        XCTAssertEqual(engine.count("containers"), 1)

        for i in 0..<5 {
            engine.emit(.container(id: "c\(i)", action: "start"))
            try? await Task.sleep(for: .milliseconds(20))
        }
        await waitUntil { engine.count("containers") >= 2 }
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(engine.count("containers"), 2, "5 events inside the debounce window → exactly 1 refresh")
    }

    func test_event_otherEventsDoNotRefresh() async {
        let engine = FakeEngine()
        let model = makeModel(engine: engine, shell: FakeColimaShell(running: true), store: makeStore(), debounce: .milliseconds(30))
        await model.bootstrap()
        engine.emit(.other)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.count("containers"), 1)
    }

    func test_startColima_thenLive() async throws {
        let store = makeStore()
        try store.save(oldSnapshot)
        let engine = FakeEngine(containers: [container("fresh")])
        let shell = FakeColimaShell(running: false)
        let model = makeModel(engine: engine, shell: shell, store: store)
        await model.bootstrap()
        XCTAssertEqual(model.connection, .colimaStopped(lastSnapshot: savedAt))

        await model.startColima()

        XCTAssertTrue(shell.calls.contains(["colima", "start", "-p", "default"]))
        XCTAssertEqual(model.connection, .live)
        XCTAssertEqual(model.containers.map(\.name), ["fresh"], "live data replaces the snapshot")
        XCTAssertEqual(store.load()?.containers.map(\.name), ["fresh"], "snapshot refreshed")
        XCTAssertFalse(model.colimaBusy)
    }

    func test_stopColima_goesToStoppedKeepingData() async {
        let engine = FakeEngine(containers: [container("web")])
        let shell = FakeColimaShell(running: true)
        let model = makeModel(engine: engine, shell: shell, store: makeStore())
        await model.bootstrap()

        await model.stopColima()

        XCTAssertTrue(shell.calls.contains(["colima", "stop", "-p", "default"]))
        guard case .colimaStopped = model.connection else { return XCTFail("got \(model.connection)") }
        XCTAssertFalse(model.canMutate)
        XCTAssertEqual(model.containers.map(\.name), ["web"])
    }

    func test_startColima_failure_isReported_andStaysStopped() async {
        let model = AppModel(locate: { SocketInfo(path: "/tmp/fake.sock", profile: "default") },
                             engineFactory: { _ in FakeEngine() },
                             colimaFactory: { profile in ColimaService(profile: profile, home: URL(fileURLWithPath: "/nonexistent-home")) { _, args in
                                 if args.first == "start" { throw ShellError.failed(exe: "colima", code: 1, stderr: "boom") }
                                 throw ShellError.failed(exe: "colima", code: 1, stderr: "not running")
                             } },
                             store: makeStore(), debounce: .milliseconds(10), pollInterval: nil)
        await model.bootstrap()
        await model.startColima()
        XCTAssertEqual(model.lastError, "boom")
        guard case .colimaStopped = model.connection else { return XCTFail("got \(model.connection)") }
    }

    func test_usage_reflectsContainers() async {
        let engine = FakeEngine(containers: [container("db", image: "sha256:a", state: .exited, volumes: ["v1"])],
                                images: [image("sha256:a"), image("sha256:b")], volumes: [volume("v1"), volume("v2")])
        let model = makeModel(engine: engine, shell: FakeColimaShell(running: true), store: makeStore())
        await model.bootstrap()
        XCTAssertFalse(model.usage.isUnused(model.images[0]))
        XCTAssertTrue(model.usage.isUnused(model.images[1]))
        XCTAssertFalse(model.usage.isUnused(model.volumes[0]))
        XCTAssertTrue(model.usage.isUnused(model.volumes[1]))
    }

    func test_reconnect_afterRefused_goesLive() async {
        let engine = FakeEngine(containers: [container("web")])
        engine.negotiateError = DockerError.connectionRefused
        let model = makeModel(engine: engine, shell: FakeColimaShell(running: true), store: makeStore())
        await model.bootstrap()
        XCTAssertEqual(model.connection, .stale(.distantPast))

        engine.negotiateError = nil
        await model.reconnect()

        XCTAssertEqual(model.connection, .live)
        XCTAssertEqual(model.containers.map(\.name), ["web"])
    }
}
