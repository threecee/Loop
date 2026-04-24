import XCTest
@testable import WatchApp_Extension

final class GlucoseCacheTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID()).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func makeReading(minutesAgo: Double, value: Double = 120) -> GlucoseReading {
        GlucoseReading(
            valueMgDl: value,
            timestamp: Date().addingTimeInterval(-minutesAgo * 60),
            trend: .flat,
            sensorId: "TEST"
        )
    }

    func testLoadMissingFileReturnsEmpty() {
        let cache = GlucoseCache(fileURL: tempURL)
        XCTAssertEqual(cache.readings, [])
    }

    func testAppendPersists() throws {
        var cache = GlucoseCache(fileURL: tempURL)
        let reading = makeReading(minutesAgo: 0)
        try cache.append(reading)

        let reloaded = GlucoseCache(fileURL: tempURL)
        XCTAssertEqual(reloaded.readings, [reading])
    }

    func testTrimsToCapacity() throws {
        var cache = GlucoseCache(fileURL: tempURL, capacity: 3)
        try cache.append(makeReading(minutesAgo: 30, value: 100))
        try cache.append(makeReading(minutesAgo: 20, value: 110))
        try cache.append(makeReading(minutesAgo: 10, value: 120))
        try cache.append(makeReading(minutesAgo: 0, value: 130))

        XCTAssertEqual(cache.readings.count, 3)
        XCTAssertEqual(cache.readings.first?.valueMgDl, 110)  // oldest kept
        XCTAssertEqual(cache.readings.last?.valueMgDl, 130)   // newest kept
    }

    func testCorruptFileRecoveredAsEmpty() throws {
        try Data("not json".utf8).write(to: tempURL)
        let cache = GlucoseCache(fileURL: tempURL)
        XCTAssertEqual(cache.readings, [])
    }
}
