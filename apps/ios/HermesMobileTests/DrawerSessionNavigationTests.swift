import XCTest
@testable import HermesMobile

/// Every compact-drawer session source must close at the tap edge. The async
/// transcript/resume pipeline is intentionally not awaited by presentation.
@MainActor
final class DrawerSessionNavigationTests: XCTestCase {
    func testSelectionActivatesSessionBeforeClosingAndDoesNotWaitForHydration() {
        let sessions = SessionStore()
        let summary = SessionSummary(
            id: "project-session",
            title: "Project session",
            preview: nil,
            startedAt: 1,
            messageCount: 2,
            source: "app",
            lastActive: 2,
            cwd: "/repo"
        )
        var closeCount = 0
        var selectedIDObservedAtClose: String?

        DrawerSessionNavigation.open(summary, in: sessions) {
            closeCount += 1
            selectedIDObservedAtClose = sessions.activeStoredId
        }

        XCTAssertEqual(closeCount, 1, "one row tap must request one compact-drawer close")
        XCTAssertEqual(selectedIDObservedAtClose, summary.id,
                       "selection must commit synchronously before the drawer closes")
        XCTAssertEqual(sessions.activeStoredId, summary.id)
    }
}
