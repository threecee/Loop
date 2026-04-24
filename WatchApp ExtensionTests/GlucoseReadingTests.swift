import XCTest
@testable import WatchApp_Extension

final class GlucoseReadingTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let reading = GlucoseReading(
            valueMgDl: 140.0,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            trend: .flat,
            sensorId: "ABCD1234"
        )

        let encoded = try JSONEncoder().encode(reading)
        let decoded = try JSONDecoder().decode(GlucoseReading.self, from: encoded)

        XCTAssertEqual(decoded, reading)
    }

    func testEquatable() {
        let a = GlucoseReading(valueMgDl: 100, timestamp: Date(timeIntervalSince1970: 0), trend: .flat, sensorId: "X")
        let b = GlucoseReading(valueMgDl: 100, timestamp: Date(timeIntervalSince1970: 0), trend: .flat, sensorId: "X")
        let c = GlucoseReading(valueMgDl: 101, timestamp: Date(timeIntervalSince1970: 0), trend: .flat, sensorId: "X")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
