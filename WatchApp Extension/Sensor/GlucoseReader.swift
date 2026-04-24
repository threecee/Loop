import Foundation
import G7SensorKit
import LoopKit

/// Surfaces glucose readings from a G7 sensor.
///
/// Wraps `G7CGMManager` (from G7SensorKit) and observes its state changes
/// via `G7StateObserver`. Each new reading is projected into our app's
/// `GlucoseReading` type and emitted on an `AsyncStream` for UI + storage
/// consumption.
///
/// `GlucoseReader` does not own any BLE code directly — `G7CGMManager`
/// owns the `CBCentralManager` internally, which is exactly what we want:
/// we reuse the battle-tested upstream stack rather than reimplement it.
final class GlucoseReader {
    /// Stream of readings. Consumers iterate with `for await ...`.
    var readings: AsyncStream<GlucoseReading> { stream }

    private let stream: AsyncStream<GlucoseReading>
    private let continuation: AsyncStream<GlucoseReading>.Continuation
    private var manager: G7CGMManager?
    private var observer: G7Observer?
    private var lastEmittedTimestamp: Date?

    init() {
        var cont: AsyncStream<GlucoseReading>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// Attach to a G7CGMManager constructed from the shared rawState.
    /// Returns false if rawState is missing/invalid; true if attached.
    @discardableResult
    func attach(rawState: [String: Any]) -> Bool {
        guard let manager = G7CGMManager(rawState: rawState) else { return false }
        self.manager = manager
        let observer = G7Observer { [weak self] reading in self?.publish(reading) }
        self.observer = observer
        manager.addStateObserver(observer, queue: .main)
        return true
    }

    /// Exposed for tests so they can simulate incoming readings without a manager.
    func publish(_ reading: GlucoseReading) {
        // Avoid duplicate emissions when the state observer fires for unrelated
        // changes (connection status, etc.). Two readings with the same
        // timestamp are the same reading.
        if lastEmittedTimestamp == reading.timestamp {
            return
        }
        lastEmittedTimestamp = reading.timestamp
        continuation.yield(reading)
    }

    deinit {
        continuation.finish()
    }
}

/// Concrete G7StateObserver that forwards the latest reading to a closure.
/// Declared as a separate class so we can hold it strongly while allowing
/// GlucoseReader to be deallocated cleanly.
private final class G7Observer: G7StateObserver {
    private let onReading: (GlucoseReading) -> Void
    init(onReading: @escaping (GlucoseReading) -> Void) {
        self.onReading = onReading
    }

    func g7StateDidUpdate(_ state: G7CGMManagerState?) {
        guard let state,
              let msg = state.latestReading,
              let glucose = msg.glucose,
              let timestamp = state.latestReadingTimestamp else {
            return
        }
        let reading = GlucoseReading(
            valueMgDl: Double(glucose),
            timestamp: timestamp,
            trend: G7GlucoseTrend.fromG7(msg.trend),
            sensorId: state.sensorID ?? "?"
        )
        onReading(reading)
    }

    func g7ConnectionStatusDidChange() {}
}

private extension G7GlucoseTrend {
    /// Project G7SensorKit's trend rate (mg/dL per minute) into our local enum.
    /// Ranges follow the Dexcom trend convention.
    static func fromG7(_ raw: Double?) -> G7GlucoseTrend {
        guard let rate = raw else { return .notComputable }
        switch rate {
        case ..<(-3):       return .doubleDown
        case -3..<(-2):     return .singleDown
        case -2..<(-1):     return .fortyFiveDown
        case -1...1:        return .flat
        case 1..<2:         return .fortyFiveUp
        case 2..<3:         return .singleUp
        default:            return .doubleUp
        }
    }
}
