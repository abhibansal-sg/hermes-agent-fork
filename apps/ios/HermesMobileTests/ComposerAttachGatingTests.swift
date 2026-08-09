import XCTest
@testable import HermesMobile

@MainActor
final class ComposerAttachGatingTests: XCTestCase {
    func testStockAttachMenuDoesNotDependOnPluginUploadCapability() {
        let connection = ConnectionStore(sessionStore: SessionStore(), chatStore: ChatStore())

        connection.capabilities._setUploadForTesting(.unknown)
        XCTAssertTrue(connection.attachMenuAvailable)

        connection.capabilities._setUploadForTesting(.available)
        XCTAssertTrue(connection.attachMenuAvailable)

        connection.capabilities._setUploadForTesting(.unavailable)
        XCTAssertTrue(connection.attachMenuAvailable)
    }
}
