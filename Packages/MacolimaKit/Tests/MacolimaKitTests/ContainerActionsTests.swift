import XCTest
@testable import MacolimaKit

@MainActor
final class ContainerActionsTests: XCTestCase {
    private func shopEngine() -> FakeEngine {
        FakeEngine(containers: [
            container("web", state: .running, project: "shop"),
            container("db", state: .running, project: "shop"),
            container("worker", state: .exited, project: "shop"),
            container("solo", state: .exited),
        ])
    }

    private func shopGroup(_ model: AppModel) throws -> ContainerGroup {
        try XCTUnwrap(ComposeGrouping.group(model.containers).first { $0.project == "shop" })
    }

    func test_stopProject_stopsOnlyRunningMembers() async throws {
        let engine = shopEngine()
        let model = await makeLiveModel(engine)
        let outcomes = await model.stopProject(try shopGroup(model))
        XCTAssertEqual(Set(engine.calls.filter { $0.hasPrefix("stop:") }), ["stop:id-web", "stop:id-db"])
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
        XCTAssertEqual(model.containers.first { $0.name == "web" }?.state, .exited, "model refreshed after the action")
    }

    func test_startProject_startsOnlyStoppedMembers() async throws {
        let engine = shopEngine()
        let model = await makeLiveModel(engine)
        let outcomes = await model.startProject(try shopGroup(model))
        XCTAssertEqual(engine.calls.filter { $0.hasPrefix("start:") }, ["start:id-worker"])
        XCTAssertEqual(outcomes.map(\.item.name), ["worker"])
        XCTAssertEqual(model.containers.first { $0.name == "worker" }?.state, .running)
    }

    func test_projectAction_reportsPerContainerFailure_andContinues() async throws {
        let engine = shopEngine()
        engine.fail("stop:id-db", with: DockerError.http(status: 500, message: "cannot stop"))
        let model = await makeLiveModel(engine)
        let outcomes = await model.stopProject(try shopGroup(model))
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.first { $0.item.name == "db" }?.error, "cannot stop")
        XCTAssertNil(outcomes.first { $0.item.name == "web" }?.error)
        XCTAssertEqual(engine.count("stop:id-web"), 1)
    }

    func test_perform_startStopRestart() async {
        let engine = shopEngine()
        let model = await makeLiveModel(engine)
        let solo = model.containers.first { $0.name == "solo" }!
        let web = model.containers.first { $0.name == "web" }!
        _ = await model.perform(.start, on: solo)
        _ = await model.perform(.restart, on: web)
        _ = await model.perform(.stop, on: web)
        XCTAssertEqual(engine.calls.filter { $0.contains(":id-") }, ["start:id-solo", "restart:id-web", "stop:id-web"])
    }

    func test_deleteContainer_callsRemoveWithoutForceOrVolumes() async {
        let engine = shopEngine()
        let model = await makeLiveModel(engine)
        let solo = model.containers.first { $0.name == "solo" }!
        let outcome = await model.perform(.delete, on: solo)
        XCTAssertNil(outcome.error)
        // The engine call carries no force/volume flag at all; DockerAPI pins v=0&force=0 (DockerAPITests).
        XCTAssertEqual(engine.calls.filter { $0.hasPrefix("remove") }, ["removeContainer:id-solo"])
        XCTAssertFalse(model.containers.contains { $0.name == "solo" })
    }

    func test_actions_whenNotLive_doNothingAndSayWhy() async throws {
        let engine = shopEngine()
        let model = await makeLiveModel(engine, running: false)
        let web = container("web", state: .running, project: "shop")
        let outcome = await model.perform(.stop, on: web)
        XCTAssertNotNil(outcome.error)
        let group = ContainerGroup(project: "shop", containers: [web])
        let project = await model.stopProject(group)
        XCTAssertEqual(project.compactMap(\.error).count, 1)
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func test_logs_checksTTYThenStreamsWithTail() async throws {
        let engine = shopEngine()
        engine.ttyContainerIDs = ["id-web"]
        engine.logLines = [LogLine(stream: .stdout, text: "hi")]
        let model = await makeLiveModel(engine)
        let web = model.containers.first { $0.name == "web" }!
        var lines: [LogLine] = []
        for try await l in model.logs(for: web, tail: 300) { lines.append(l) }
        XCTAssertEqual(lines.map(\.text), ["hi"])
        XCTAssertEqual(engine.calls.filter { $0.hasPrefix("isTTY") || $0.hasPrefix("logs") }, ["isTTY:id-web", "logs:id-web:tail=300:tty=true"])
    }
}
