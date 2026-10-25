import XCTest
@testable import MacolimaKit

final class MenuBarSummaryTests: XCTestCase {
    func test_splitsActiveFromStopped_sortedByName() {
        let summary = MenuBarSummary(containers: [
            container("web", state: .running),
            container("api", state: .running),
            container("job", state: .exited),
            container("cache", state: .paused),
            container("old", state: .created),
            container("gone", state: .removing),
        ])
        XCTAssertEqual(summary.active.map(\.name), ["api", "cache", "web"])
        XCTAssertEqual(summary.stopped.map(\.name), ["job", "old"])
        XCTAssertEqual(summary.activeCount, 3)
    }

    func test_capsStoppedList_andCountsTheRest() {
        let many = (1...8).map { container("c\($0)", state: .exited) }
        let summary = MenuBarSummary(containers: many, stoppedLimit: 5)
        XCTAssertEqual(summary.stopped.count, 5)
        XCTAssertEqual(summary.hiddenStoppedCount, 3)
    }

    func test_empty() {
        let summary = MenuBarSummary(containers: [])
        XCTAssertEqual(summary.activeCount, 0)
        XCTAssertTrue(summary.stopped.isEmpty)
        XCTAssertEqual(summary.hiddenStoppedCount, 0)
    }
}
