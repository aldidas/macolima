import XCTest
@testable import MacolimaKit

@MainActor
final class ImageActionsTests: XCTestCase {
    /// `used` is held by a stopped container, `dangling` by a container referencing its id, `free1/free2` by nobody.
    private func engine() -> FakeEngine {
        FakeEngine(containers: [container("db", image: "sha256:used", state: .exited),
                                container("old", image: "sha256:dangling", state: .exited)],
                   images: [image("sha256:used", size: 900), image("sha256:dangling", tags: [], size: 300),
                            image("sha256:free1", size: 200), image("sha256:free2", size: 100)])
    }

    func test_deleteImages_skipsInUse_reportsError() async {
        let e = engine()
        let model = await makeLiveModel(e)
        let used = model.images.first { $0.id == "sha256:used" }!
        let free = model.images.first { $0.id == "sha256:free1" }!
        let outcomes = await model.deleteImages([used, free])

        XCTAssertEqual(outcomes.map(\.item.id), ["sha256:used", "sha256:free1"], "input order kept")
        XCTAssertEqual(outcomes[0].error, "In use by container “db”")
        XCTAssertNil(outcomes[1].error)
        XCTAssertEqual(e.calls.filter { $0.hasPrefix("removeImage") }, ["removeImage:sha256:free1"], "in-use image never reaches the engine")
        XCTAssertEqual(Set(model.images.map(\.id)), ["sha256:used", "sha256:dangling", "sha256:free2"])
    }

    func test_deleteImages_danglingImageHeldByIDIsBlocked() async {
        let e = engine()
        let model = await makeLiveModel(e)
        let dangling = model.images.first { $0.id == "sha256:dangling" }!
        let outcomes = await model.deleteImages([dangling])
        XCTAssertEqual(outcomes.first?.error, "In use by container “old”")
        XCTAssertTrue(e.calls.filter { $0.hasPrefix("removeImage") }.isEmpty)
    }

    func test_pruneUnusedImages_removesOnlyUnused() async {
        let e = engine()
        let model = await makeLiveModel(e)
        let outcomes = await model.pruneUnused(model.unusedImagesPlan)
        XCTAssertEqual(Set(outcomes.map(\.item.id)), ["sha256:free1", "sha256:free2"])
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
        XCTAssertEqual(Set(model.images.map(\.id)), ["sha256:used", "sha256:dangling"])
    }

    func test_pruneUnusedImages_partialFailureReported() async {
        let e = engine()
        e.fail("removeImage:sha256:free1", with: DockerError.http(status: 409, message: "image is being used by a container"))
        let model = await makeLiveModel(e)
        let outcomes = await model.pruneUnused(model.unusedImagesPlan)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.first { $0.item.id == "sha256:free1" }?.error, "image is being used by a container")
        XCTAssertNil(outcomes.first { $0.item.id == "sha256:free2" }?.error)
        XCTAssertTrue(model.images.contains { $0.id == "sha256:free1" })
        XCTAssertFalse(model.images.contains { $0.id == "sha256:free2" })
    }

    func test_unusedImagesPlan_matchesPrunePreview() async {
        let model = await makeLiveModel(engine())
        let plan = model.unusedImagesPlan
        XCTAssertEqual(plan.items.map(\.id), ["sha256:free1", "sha256:free2"])
        XCTAssertEqual(plan.knownBytes, 300)
    }

    func test_imageActions_whenNotLive_doNothing() async {
        let e = engine()
        let model = await makeLiveModel(e, running: false)
        let outcomes = await model.pruneUnused(model.unusedImagesPlan)
        XCTAssertTrue(outcomes.isEmpty || outcomes.allSatisfy { $0.error != nil })
        let del = await model.deleteImages([image("sha256:free1")])
        XCTAssertNotNil(del.first?.error)
        XCTAssertTrue(e.calls.isEmpty)
    }

    func test_pruneUnusedImages_removesOnlyThePreviewedPlan_evenIfStateChangedMeanwhile() async {
        let e = engine()
        let model = await makeLiveModel(e)
        let previewed = model.unusedImagesPlan                        // [free1, free2]; used + dangling are held
        let db = model.containers.first { $0.name == "db" }!
        _ = await model.perform(.delete, on: db)                      // "used" is now unreferenced but was never shown
        XCTAssertTrue(model.usage.isUnused(model.images.first { $0.id == "sha256:used" }!))

        let outcomes = await model.pruneUnused(previewed)

        XCTAssertEqual(Set(outcomes.map(\.item.id)), ["sha256:free1", "sha256:free2"])
        XCTAssertFalse(e.calls.contains("removeImage:sha256:used"))
    }
}
