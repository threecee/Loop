import Foundation

/// Reads shared state written by Loop iOS into the App Group's UserDefaults.
///
/// Loop iOS persists its `CGMManager.RawValue` (a dict) under the key
/// `com.loopkit.Loop.CGMManagerState` in the App Group UserDefaults. When
/// Loop iOS has paired with a G7 sensor, that dict contains a sensor ID we
/// can reuse to connect to the same sensor from watchOS — no re-pairing
/// required (G7 supports multiple concurrent readers).
struct SharedStateBridge {
    /// Key Loop iOS writes the CGMManager.RawValue under. From
    /// Loop/Extensions/UserDefaults+Loop.swift.
    static let cgmManagerStateKey = "com.loopkit.Loop.CGMManagerState"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Constructs a bridge using the App Group UserDefaults. Returns nil if
    /// the App Group entitlement is misconfigured (defaults initializer fails
    /// silently; we surface it).
    static func forAppGroup(_ identifier: String) -> SharedStateBridge? {
        guard let defaults = UserDefaults(suiteName: identifier) else { return nil }
        return SharedStateBridge(defaults: defaults)
    }

    /// Returns the G7 sensor ID currently paired to Loop iOS, or nil if
    /// no G7 is paired / state not yet written.
    func loadG7SensorID() -> String? {
        guard let raw = defaults.dictionary(forKey: Self.cgmManagerStateKey) else {
            return nil
        }
        guard let cgmType = raw["cgmManagerRawType"] as? String, cgmType == "G7CGMManager" else {
            return nil
        }
        guard let state = raw["state"] as? [String: Any] else {
            return nil
        }
        return state["sensorID"] as? String
    }

    /// Returns the full G7 state dict for constructing a G7CGMManager via
    /// its `init(rawState:)`. Returns nil if no G7 is paired.
    func loadG7RawState() -> [String: Any]? {
        guard let raw = defaults.dictionary(forKey: Self.cgmManagerStateKey) else { return nil }
        guard let cgmType = raw["cgmManagerRawType"] as? String, cgmType == "G7CGMManager" else { return nil }
        return raw["state"] as? [String: Any]
    }
}
