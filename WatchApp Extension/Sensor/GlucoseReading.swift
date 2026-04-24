import Foundation

/// A single glucose reading from a G7 sensor, normalized into our app's domain.
/// Decoupled from G7SensorKit's internal types so we control the storage shape
/// of `GlucoseCache`'s JSON file (which can evolve independently of G7SensorKit).
struct GlucoseReading: Codable, Equatable, Hashable {
    /// Glucose value in mg/dL. Loop uses mg/dL internally regardless of display unit.
    let valueMgDl: Double

    /// When the sensor produced this reading (not when we received it).
    let timestamp: Date

    /// Direction/rate of change. See G7GlucoseTrend.
    let trend: G7GlucoseTrend

    /// The G7 sensor's ID that produced this reading. Used to detect sensor changes.
    let sensorId: String
}

/// Mirrors the trends G7SensorKit and LoopKit expose. Kept as a local enum so our
/// cache format isn't coupled to upstream enum cases. Named G7GlucoseTrend to
/// avoid shadowing LoopKit.GlucoseTrend in the WatchApp Extension module.
enum G7GlucoseTrend: String, Codable, CaseIterable {
    case doubleUp, singleUp, fortyFiveUp, flat, fortyFiveDown, singleDown, doubleDown
    case notComputable
}
