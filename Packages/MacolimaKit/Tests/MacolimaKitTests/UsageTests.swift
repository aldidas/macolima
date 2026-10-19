import XCTest
@testable import MacolimaKit

final class UsageTests: XCTestCase {
    func test_stoppedContainerStillCountsAsUsingImage() {
        let usage = UsageIndex(containers: [container("db", image: "img1", state: .exited)])
        XCTAssertFalse(usage.isUnused(image("img1")))
        XCTAssertEqual(usage.containersUsing(image: image("img1")).map(\.name), ["db"])
        XCTAssertTrue(usage.isUnused(image("img2")))
    }

    func test_danglingImageUsedByIDIsNotUnused() {
        let dangling = image("sha256:dead", tags: [])
        let usage = UsageIndex(containers: [container("old", image: "sha256:dead", state: .exited)])
        XCTAssertFalse(usage.isUnused(dangling))
    }

    func test_volumeUsedOnlyByStoppedContainerIsNotUnused() {
        let usage = UsageIndex(containers: [container("db", state: .exited, volumes: ["pgdata"])])
        XCTAssertFalse(usage.isUnused(volume("pgdata")))
        XCTAssertEqual(usage.containersUsing(volume: volume("pgdata")).map(\.name), ["db"])
        XCTAssertTrue(usage.isUnused(volume("scratch")))
    }

    func test_group_standaloneLast_projectsSorted_runningCount() {
        let groups = ComposeGrouping.group([
            container("solo"),
            container("b-web", project: "beta"),
            container("a-web", state: .exited, project: "alpha"),
            container("a-db", project: "alpha"),
        ])
        XCTAssertEqual(groups.map(\.project), ["alpha", "beta", nil])
        XCTAssertEqual(groups[0].containers.map(\.name), ["a-db", "a-web"])
        XCTAssertEqual(groups[0].runningCount, 1)
        XCTAssertEqual(groups[2].runningCount, 1)
    }

    func test_group_noContainers_isEmpty() {
        XCTAssertTrue(ComposeGrouping.group([]).isEmpty)
    }
}
