//
//  NightscoutServiceLoadingTest.swift
//  WatchApp Extension Tests
//
//  B.3.a Phase 3.B — Outcome B: static link smoke test.
//
//  Dynamic plugin loading (Bundle.allFrameworks / principalClass) is blocked on
//  watchOS extensions:
//    • No PluginManager / ServicesManager in WatchApp Extension
//    • NightscoutServiceKitPlugin requires LoopKitUI (iOS-only)
//    • watchOS sandbox does not support Loop's Bundle.principalClass discovery
//
//  NightscoutServiceKit is therefore statically linked into the WatchApp Extension
//  target. Explicit service registration in WatchRemoteCommandBootstrap follows in
//  Phase 5. This test verifies the static link is reachable at runtime on watchOS.
//

import XCTest
import NightscoutServiceKit

final class NightscoutServiceLoadingTest: XCTestCase {

    /// Outcome B: static link smoke test.
    /// Verifies NightscoutServiceKit.framework is loadable from the watchOS
    /// extension and that the core service can be instantiated.
    func testNightscoutServiceCanBeStaticallyConstructedOnWatch() {
        let svc = NightscoutService()
        XCTAssertNotNil(svc, "NightscoutService should be constructable on watchOS via static link")
    }

    /// Verifies the service has a non-empty pluginIdentifier — the key used
    /// by Loop's RemoteDataServicesManager to route data.
    func testNightscoutServiceHasPluginIdentifier() {
        let svc = NightscoutService()
        XCTAssertFalse(svc.pluginIdentifier.isEmpty,
                       "pluginIdentifier should not be empty on watchOS")
    }
}
