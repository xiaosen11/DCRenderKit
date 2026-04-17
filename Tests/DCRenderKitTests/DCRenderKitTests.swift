import XCTest
@testable import DCRenderKit

final class DCRenderKitTests: XCTestCase {
    func testVersionExists() {
        XCTAssertFalse(DCRenderKit.version.isEmpty, "Version string must be set")
    }
}
