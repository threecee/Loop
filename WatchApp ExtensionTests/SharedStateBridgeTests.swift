import XCTest
@testable import WatchApp_Extension

final class SharedStateBridgeTests: XCTestCase {

    func testMissingStateReturnsNil() {
        let defaults = UserDefaults(suiteName: "group.test.empty-\(UUID())")!
        let bridge = SharedStateBridge(defaults: defaults)
        XCTAssertNil(bridge.loadG7SensorID())
    }

    func testValidStateReturnsSensorID() {
        let defaults = UserDefaults(suiteName: "group.test.valid-\(UUID())")!
        defaults.set([
            "cgmManagerRawType": "G7CGMManager",
            "state": [
                "sensorID": "SENS1234",
                "activatedAt": Date(),
            ],
        ], forKey: SharedStateBridge.cgmManagerStateKey)

        let bridge = SharedStateBridge(defaults: defaults)
        XCTAssertEqual(bridge.loadG7SensorID(), "SENS1234")
    }

    func testNonG7CGMManagerReturnsNil() {
        let defaults = UserDefaults(suiteName: "group.test.non-g7-\(UUID())")!
        defaults.set([
            "cgmManagerRawType": "SomeOtherCGM",
            "state": ["foo": "bar"],
        ], forKey: SharedStateBridge.cgmManagerStateKey)

        let bridge = SharedStateBridge(defaults: defaults)
        XCTAssertNil(bridge.loadG7SensorID())
    }
}
