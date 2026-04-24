import XCTest
import SwiftUI
@testable import WatchApp_Extension

final class ExtendedRuntimeCoordinatorTests: XCTestCase {

    func testStartsSessionOnActiveScene() {
        let session = MockExtendedRuntimeSession()
        let coordinator = ExtendedRuntimeCoordinator(sessionFactory: { session })

        coordinator.onScenePhaseChange(.active)

        XCTAssertEqual(session.startCallCount, 1)
    }

    func testInvalidatesSessionOnBackgroundScene() {
        let session = MockExtendedRuntimeSession()
        let coordinator = ExtendedRuntimeCoordinator(sessionFactory: { session })

        coordinator.onScenePhaseChange(.active)
        coordinator.onScenePhaseChange(.background)

        XCTAssertEqual(session.invalidateCallCount, 1)
    }

    func testRapidTransitionsDontDoubleStart() {
        let session = MockExtendedRuntimeSession()
        let coordinator = ExtendedRuntimeCoordinator(sessionFactory: { session })

        coordinator.onScenePhaseChange(.active)
        coordinator.onScenePhaseChange(.active)  // duplicate

        XCTAssertEqual(session.startCallCount, 1)
    }
}

final class MockExtendedRuntimeSession: ExtendedRuntimeSessionProtocol {
    var startCallCount = 0
    var invalidateCallCount = 0
    func start() { startCallCount += 1 }
    func invalidate() { invalidateCallCount += 1 }
}
