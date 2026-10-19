import XCTest
@testable import MacolimaKit

final class PruneTests: XCTestCase {
    func test_unusedImages_onlyUnreferenced_withTotals() {
        let usage = UsageIndex(containers: [container("c", image: "used", state: .exited)])
        let plan = PrunePlanner.unusedImages([image("used", size: 500), image("a", size: 10), image("b", size: 30)], usage: usage)
        XCTAssertEqual(plan.items.map(\.id), ["b", "a"])   // largest first
        XCTAssertEqual(plan.knownBytes, 40)
        XCTAssertEqual(plan.unknownSizeCount, 0)
    }

    func test_unusedVolumes_sizeNilCountedInUnknownNotBytes() {
        let usage = UsageIndex(containers: [container("c", volumes: ["inuse"])])
        let plan = PrunePlanner.unusedVolumes([volume("inuse", size: 999), volume("known", size: 7), volume("mystery", size: nil)], usage: usage)
        XCTAssertEqual(plan.items.map(\.name), ["known", "mystery"])   // unknown last
        XCTAssertEqual(plan.knownBytes, 7)
        XCTAssertEqual(plan.unknownSizeCount, 1)
    }

    func test_pruner_continuesAfterFailure_andReportsPerItem() async {
        struct Boom: Error {}
        let plan = PrunePlan(items: ["one", "two", "three"], knownBytes: 0, unknownSizeCount: 0)
        let removed = Recorder()
        let outcomes = await Pruner.run(plan) { item in
            if item == "two" { throw DockerError.http(status: 409, message: "image is in use") }
            await removed.add(item)
        }
        XCTAssertEqual(outcomes.map(\.item), ["one", "two", "three"])
        XCTAssertEqual(outcomes.map(\.error), [nil, "image is in use", nil])
        let got = await removed.items
        XCTAssertEqual(got, ["one", "three"])
    }
}

private actor Recorder {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
