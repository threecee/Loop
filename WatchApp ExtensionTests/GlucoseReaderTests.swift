import XCTest
@testable import WatchApp_Extension

final class GlucoseReaderTests: XCTestCase {

    func testStreamEmitsPublishedReadings() async throws {
        let reader = GlucoseReader()
        let reading = GlucoseReading(valueMgDl: 120, timestamp: Date(), trend: .flat, sensorId: "T")

        var iterator = reader.readings.makeAsyncIterator()

        // Simulate an incoming reading on a background task.
        Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            reader.publish(reading)
        }

        let first = await iterator.next()
        XCTAssertEqual(first, reading)
    }
}
