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

/// Review finding: image sizes include layers shared with other images, so a summed total can overstate what is freed.
final class PruneSummaryTests: XCTestCase {
    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    func test_exactTotal_saysFrees() {
        XCTAssertEqual(PruneSummary.text(count: 2, knownBytes: 3_000_000, unknownSizeCount: 0, sizesAreShared: false),
                       "2 items · frees \(bytes(3_000_000)) inside the VM")
    }

    func test_sharedLayerSizes_sayUpTo_andExplain() {
        let text = PruneSummary.text(count: 5, knownBytes: 5_000_000_000, unknownSizeCount: 0, sizesAreShared: true)
        XCTAssertTrue(text.contains("frees up to \(bytes(5_000_000_000))"), text)
        XCTAssertTrue(text.contains("shared"), text)
    }

    func test_unknownSizes_areListedSeparately_neverAsZero() {
        XCTAssertEqual(PruneSummary.text(count: 1, knownBytes: 0, unknownSizeCount: 1, sizesAreShared: false),
                       "1 item · frees \(bytes(0)) + 1 item of unknown size inside the VM")
    }

    func test_planConvenience_matchesFreeFunction() {
        let plan = PrunePlan(items: ["a", "b"], knownBytes: 10, unknownSizeCount: 2)
        XCTAssertEqual(plan.summary(sizesAreShared: true), PruneSummary.text(count: 2, knownBytes: 10, unknownSizeCount: 2, sizesAreShared: true))
    }
}
