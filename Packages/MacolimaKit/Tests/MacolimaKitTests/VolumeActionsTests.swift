import XCTest
@testable import MacolimaKit

@MainActor
final class VolumeActionsTests: XCTestCase {
    /// `pgdata` is only referenced by a stopped container; `cache` and `mystery` (size unknown) by nobody.
    private func engine() -> FakeEngine {
        FakeEngine(containers: [container("db", state: .exited, volumes: ["pgdata"])],
                   volumes: [volume("pgdata", size: 5000), volume("cache", size: 300), volume("mystery", size: nil)])
    }

    func test_pruneUnusedVolumes_keepsVolumeUsedByStoppedContainer() async {
        let e = engine()
        let model = await makeLiveModel(e)
        let outcomes = await model.pruneUnusedVolumes()
        XCTAssertEqual(Set(outcomes.map(\.item.name)), ["cache", "mystery"])
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
        XCTAssertEqual(model.volumes.map(\.name), ["pgdata"])
        XCTAssertFalse(e.calls.contains("removeVolume:pgdata"))
    }

    func test_pruneUnusedVolumes_partialFailureReportedPerItem() async {
        let e = engine()
        e.fail("removeVolume:cache", with: DockerError.http(status: 404, message: "no such volume"))
        let model = await makeLiveModel(e)
        let outcomes = await model.pruneUnusedVolumes()
        XCTAssertEqual(outcomes.first { $0.item.name == "cache" }?.error, "no such volume")
        XCTAssertNil(outcomes.first { $0.item.name == "mystery" }?.error)
    }

    func test_unusedVolumesPlan_unknownSizeNotCountedAsBytes() async {
        let model = await makeLiveModel(engine())
        let plan = model.unusedVolumesPlan
        XCTAssertEqual(plan.items.map(\.name), ["cache", "mystery"])
        XCTAssertEqual(plan.knownBytes, 300)
        XCTAssertEqual(plan.unknownSizeCount, 1)
    }

    func test_deleteVolumes_neverForce() async {
        // A volume a container still references is handed to the engine unforced; the engine's refusal is
        // reported per item and the volume stays (DockerAPI pins force=0, see DockerAPITests).
        let e = engine()
        e.fail("removeVolume:pgdata", with: DockerError.http(status: 409, message: "volume is in use"))
        let model = await makeLiveModel(e)
        let outcomes = await model.deleteVolumes(model.volumes.filter { $0.name == "pgdata" || $0.name == "cache" })
        XCTAssertEqual(outcomes.map(\.item.name), ["pgdata", "cache"])
        XCTAssertEqual(outcomes[0].error, "volume is in use")
        XCTAssertNil(outcomes[1].error)
        XCTAssertTrue(model.volumes.contains { $0.name == "pgdata" })
        XCTAssertFalse(model.volumes.contains { $0.name == "cache" })
    }

    func test_unknownSizeSortsLast() {
        let vols = [volume("a", size: nil), volume("b", size: 10), volume("c", size: 30), volume("d", size: nil), volume("e", size: 20)]
        XCTAssertEqual(VolumeOrdering.unknownLast(vols.sorted { ($0.size ?? 0) > ($1.size ?? 0) }).map(\.name), ["c", "e", "b", "a", "d"])
        XCTAssertEqual(VolumeOrdering.unknownLast(vols.sorted { ($0.size ?? 0) < ($1.size ?? 0) }).map(\.name), ["b", "e", "c", "a", "d"],
                       "still last when sorted ascending")
    }

    func test_volumeActions_whenNotLive_doNothing() async {
        let e = engine()
        let model = await makeLiveModel(e, running: false)
        let del = await model.deleteVolumes([volume("cache")])
        XCTAssertNotNil(del.first?.error)
        let pruned = await model.pruneUnusedVolumes()
        XCTAssertTrue(pruned.isEmpty)
        XCTAssertTrue(e.calls.isEmpty)
    }
}
