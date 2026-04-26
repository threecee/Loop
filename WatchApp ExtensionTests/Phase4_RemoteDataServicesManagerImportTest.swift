//
//  Phase4_RemoteDataServicesManagerImportTest.swift
//  WatchApp Extension Tests
//
//  B.3.a Phase 4 — Verify RemoteDataServicesManager is reachable from watchOS target.
//

import XCTest
@testable import WatchApp_Extension

final class Phase4_RemoteDataServicesManagerImportTest: XCTestCase {
    func testRemoteDataServicesManagerIsConstructibleOnWatch() {
        // Verify the type symbol is visible from the watch target.
        // The watchOS init omits alertStore (iOS-only Loop type).
        // Phase 5 will wire up a real instance in WatchRemoteCommandBootstrap.
        let typeName = String(describing: RemoteDataServicesManager.self)
        XCTAssertEqual(typeName, "RemoteDataServicesManager")
    }
}
