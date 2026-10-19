import XCTest
@testable import MacolimaKit

final class ScaffoldTests: XCTestCase {
    func test_kitName() {
        XCTAssertEqual(MacolimaKit.name, "MacolimaKit")
    }
}
