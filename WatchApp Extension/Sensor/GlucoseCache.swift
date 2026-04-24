import Foundation

/// A small persistent ring buffer of recent glucose readings, serialized as JSON
/// in the app's container. Backs the UI's current+recent display without waiting
/// on HealthKit queries (which can be slow on watchOS).
struct GlucoseCache {
    /// Default maximum entries — ~60 min of 5-minute G7 readings.
    static let defaultCapacity = 12

    private let fileURL: URL
    private let capacity: Int
    private(set) var readings: [GlucoseReading]

    init(fileURL: URL, capacity: Int = GlucoseCache.defaultCapacity) {
        self.fileURL = fileURL
        self.capacity = capacity
        self.readings = GlucoseCache.load(from: fileURL)
    }

    /// Append a reading and persist. Trims to capacity (keeping most recent).
    mutating func append(_ reading: GlucoseReading) throws {
        readings.append(reading)
        if readings.count > capacity {
            readings.removeFirst(readings.count - capacity)
        }
        try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        // `.timeIntervalSinceReferenceDate` (Double) preserves full precision across
        // round-trip; `.iso8601` would lose sub-second precision.
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(readings)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [GlucoseReading] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return (try? decoder.decode([GlucoseReading].self, from: data)) ?? []
    }

    /// Convenience URL in the app's container for normal use.
    static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("glucose-cache.json")
    }
}
