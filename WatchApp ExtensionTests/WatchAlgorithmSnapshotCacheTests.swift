//
//  WatchAlgorithmSnapshotCacheTests.swift
//

import XCTest
@testable import WatchApp_Extension
import OmniBLE

final class WatchAlgorithmSnapshotCacheTests: XCTestCase {

    private var defaults: UserDefaults!
    private var sut: WatchAlgorithmSnapshotCache!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.WatchAlgorithmSnapshotCache.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        sut = WatchAlgorithmSnapshotCache(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        sut = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeSnapshot(at date: Date) -> AlgorithmStateSnapshot {
        AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: date,
            phoneIterationDate: date,
            glucoseSamples: [],
            doseHistory: [],
            carbEntries: [],
            pumpStatus: PumpStatusSnapshot(reservoirUnitsRemaining: 100,
                                           lastBasalRateUnitsPerHour: 0.5,
                                           isSuspended: false,
                                           lastReadingDate: date),
            activeOverride: nil
        )
    }

    func test_initialState_isEmpty() {
        XCTAssertNil(sut.current)
    }

    func test_update_storesSnapshot() {
        let snap = makeSnapshot(at: Date())
        sut.update(snap)
        XCTAssertEqual(sut.current?.snapshotID, snap.snapshotID)
    }

    func test_update_dropsOlderSnapshot() {
        let now = Date()
        let newer = makeSnapshot(at: now)
        let older = makeSnapshot(at: now.addingTimeInterval(-60))
        sut.update(newer)
        sut.update(older)
        XCTAssertEqual(sut.current?.snapshotID, newer.snapshotID,
                       "Older snapshot must not overwrite newer")
    }

    func test_persistence_acrossReinit() {
        let snap = makeSnapshot(at: Date())
        sut.update(snap)
        let reborn = WatchAlgorithmSnapshotCache(defaults: defaults)
        XCTAssertEqual(reborn.current?.snapshotID, snap.snapshotID)
    }
}
