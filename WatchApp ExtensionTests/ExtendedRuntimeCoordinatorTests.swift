import XCTest
import SwiftUI
import Combine
import OmniBLE
@testable import WatchApp_Extension

final class ExtendedRuntimeCoordinatorTests: XCTestCase {

    /// Helper: drains the main run loop one turn so Combine sinks scheduled
    /// via `.receive(on: DispatchQueue.main)` actually fire before assertions.
    private func drainMain() {
        let exp = expectation(description: "main-queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    /// Helper: build a coordinator wired to a CurrentValueSubject of HandoffState.
    /// Returns the (coordinator, mock-session, state-subject) triple.
    private func makeCoordinator(
        initialState: HandoffState = .phoneDriver
    ) -> (ExtendedRuntimeCoordinator, MockExtendedRuntimeSession, CurrentValueSubject<HandoffState, Never>) {
        let session = MockExtendedRuntimeSession()
        let coordinator = ExtendedRuntimeCoordinator(sessionFactory: { session })
        let subject = CurrentValueSubject<HandoffState, Never>(initialState)
        coordinator.bindHandoffStatePublisher(subject.eraseToAnyPublisher())
        drainMain()
        return (coordinator, session, subject)
    }

    func testStartsSessionOnActiveScene_WhenWatchIsDriver() {
        let (coordinator, session, _) = makeCoordinator(initialState: .watchDriver)

        coordinator.onScenePhaseChange(.active)

        XCTAssertEqual(session.startCallCount, 1)
    }

    func testInvalidatesSessionOnBackgroundScene() {
        let (coordinator, session, _) = makeCoordinator(initialState: .watchDriver)

        coordinator.onScenePhaseChange(.active)
        coordinator.onScenePhaseChange(.background)

        XCTAssertEqual(session.invalidateCallCount, 1)
    }

    func testRapidTransitionsDontDoubleStart() {
        let (coordinator, session, _) = makeCoordinator(initialState: .watchDriver)

        coordinator.onScenePhaseChange(.active)
        coordinator.onScenePhaseChange(.active)  // duplicate

        XCTAssertEqual(session.startCallCount, 1)
    }

    // MARK: - B.9 efficiency #6: gate on watch-is-driver

    func testDoesNotStartWhenPhoneIsDriver() {
        let (coordinator, session, _) = makeCoordinator(initialState: .phoneDriver)

        coordinator.onScenePhaseChange(.active)

        XCTAssertEqual(session.startCallCount, 0,
                       "session must not start while phone is driver — watch is just a viewer")
    }

    func testStartsWhenWatchBecomesDriverWhileSceneActive() {
        let (coordinator, session, subject) = makeCoordinator(initialState: .phoneDriver)
        coordinator.onScenePhaseChange(.active)
        XCTAssertEqual(session.startCallCount, 0, "precondition: phone driver, no session")

        // Transition to watchDriver via the orchestrator's published state.
        subject.send(.watchDriver)
        drainMain()

        XCTAssertEqual(session.startCallCount, 1,
                       "session starts when ownership flips to watch while scene is active")
    }

    func testInvalidatesWhenWatchLosesDriver() {
        let (coordinator, session, subject) = makeCoordinator(initialState: .watchDriver)
        coordinator.onScenePhaseChange(.active)
        XCTAssertEqual(session.startCallCount, 1, "precondition: session running")

        // Hand off back to phone.
        subject.send(.phoneDriver)
        drainMain()

        XCTAssertEqual(session.invalidateCallCount, 1,
                       "session must stop when ownership leaves the watch")
    }
}

final class MockExtendedRuntimeSession: ExtendedRuntimeSessionProtocol {
    var startCallCount = 0
    var invalidateCallCount = 0
    func start() { startCallCount += 1 }
    func invalidate() { invalidateCallCount += 1 }
}
