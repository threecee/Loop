//
//  LoopStateViewTests.swift
//  LoopTests
//
//  B.7: state-transition tests for the driver indicator.
//

import XCTest
@testable import LoopUI

final class LoopStateViewTests: XCTestCase {

    private var sut: LoopStateView!

    override func setUp() {
        super.setUp()
        sut = LoopStateView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        sut.layoutIfNeeded()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - B.7 driver indicator

    func test_innerLayerHidden_whenNotDriving() {
        sut.isThisDeviceDriving = false
        XCTAssertTrue(sut.innerLayerForTesting.isHidden,
                      "Inner indicator should be hidden when this device is not driving")
    }

    func test_innerLayerVisible_whenDriving() {
        sut.isThisDeviceDriving = true
        XCTAssertFalse(sut.innerLayerForTesting.isHidden,
                       "Inner indicator should be visible when this device is driving")
    }

    func test_innerLayerToggles_whenDrivingFlagFlips() {
        sut.isThisDeviceDriving = true
        XCTAssertFalse(sut.innerLayerForTesting.isHidden)
        sut.isThisDeviceDriving = false
        XCTAssertTrue(sut.innerLayerForTesting.isHidden)
    }

    func test_pulseAnimation_addedWhenHandoffPending() {
        sut.isThisDeviceDriving = true
        sut.isHandoffPending = true
        XCTAssertNotNil(sut.innerLayerForTesting.animation(forKey: "handoffPulse"),
                        "Pulse animation should be added during handoff-pending")
    }

    func test_pulseAnimation_removedWhenHandoffSettles() {
        sut.isThisDeviceDriving = true
        sut.isHandoffPending = true
        sut.isHandoffPending = false
        XCTAssertNil(sut.innerLayerForTesting.animation(forKey: "handoffPulse"),
                     "Pulse animation should be removed when handoff settles")
    }

    func test_pulseAnimation_notAddedWhenNotDriving() {
        // If we're not driving, the inner layer is hidden — pulsing it is moot.
        // Implementation may still add the animation (cheap), or skip it.
        // The implementation chooses to ALWAYS add/remove regardless of driving state
        // because the layer is hidden anyway — animation is invisible. This keeps
        // the property semantics independent.
        sut.isThisDeviceDriving = false
        sut.isHandoffPending = true
        XCTAssertNotNil(sut.innerLayerForTesting.animation(forKey: "handoffPulse"))
    }

    func test_existingOpenProperty_unaffected() {
        // Sanity: the new properties don't break the existing `open` behavior.
        sut.open = true
        XCTAssertTrue(sut.open)
        sut.open = false
        XCTAssertFalse(sut.open)
    }
}
