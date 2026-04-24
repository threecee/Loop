import Foundation
import HealthKit

/// Narrow protocol over HKHealthStore to keep HealthKitWriter testable
/// without depending on the concrete HealthKit sandbox.
protocol HealthStoreProtocol {
    func save(_ sample: HKSample) async throws
    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws
}

extension HKHealthStore: HealthStoreProtocol {
    func save(_ sample: HKSample) async throws {
        try await saveOne(sample)
    }

    private func saveOne(_ sample: HKSample) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.save([sample]) { success, error in
                if let error { cont.resume(throwing: error); return }
                if !success { cont.resume(throwing: NSError(domain: HKErrorDomain, code: -1)); return }
                cont.resume(returning: ())
            }
        }
    }

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.requestAuthorization(toShare: toShare, read: read) { success, error in
                if let error { cont.resume(throwing: error); return }
                if !success { cont.resume(throwing: NSError(domain: HKErrorDomain, code: HKError.errorAuthorizationDenied.rawValue)); return }
                cont.resume(returning: ())
            }
        }
    }
}

/// Writes glucose readings to HealthKit, and requests broad read access so the
/// watch app can later surface or relay all the health data the device tracks.
struct HealthKitWriter {
    static let glucoseType = HKQuantityType(.bloodGlucose)
    static let mgDL = HKUnit(from: "mg/dL")

    /// Types LoopWatchApp will write to HealthKit.
    /// - `bloodGlucose`: G7 readings echoed from the watch (B.2.a).
    /// - `insulinDelivery`: doses the watch commands once it owns the pump (B.2.e).
    /// - `dietaryCarbohydrates`: future carb-entry UI on the watch.
    /// Asking for all three up front avoids re-prompting later — HealthKit only
    /// surfaces the permission sheet once per type, ever.
    static let typesToShare: Set<HKSampleType> = [
        HKQuantityType(.bloodGlucose),
        HKQuantityType(.insulinDelivery),
        HKQuantityType(.dietaryCarbohydrates),
    ]

    /// Types LoopWatchApp will read. Comprehensive on purpose: every signal Apple
    /// Watch can surface plus the diabetes triad for read-back. Pulse / sleep /
    /// activity feed the future C.3 dashboard pipeline.
    static let typesToRead: Set<HKObjectType> = {
        var set: Set<HKObjectType> = [
            // Diabetes read-back
            HKQuantityType(.bloodGlucose),
            HKQuantityType(.insulinDelivery),
            HKQuantityType(.dietaryCarbohydrates),
            // Heart
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.oxygenSaturation),
            // Activity
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.basalEnergyBurned),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.appleStandTime),
            HKQuantityType(.stepCount),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.flightsClimbed),
            // Fitness
            HKQuantityType(.vo2Max),
            // Vitals
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.bodyMass),
            // Categorical
            HKCategoryType(.sleepAnalysis),
            HKCategoryType(.appleStandHour),
            // Workouts
            HKObjectType.workoutType(),
        ]
        return set
    }()

    private let store: HealthStoreProtocol

    init(store: HealthStoreProtocol = HKHealthStore()) {
        self.store = store
    }

    /// Requests authorization for the full share + read set. Safe to call multiple
    /// times; HealthKit only prompts the user once per type. Adding new types in
    /// future versions will trigger a fresh prompt for just the additions.
    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: Self.typesToShare, read: Self.typesToRead)
    }

    /// Writes a single glucose reading. The sensor ID is included in metadata
    /// so future reads can distinguish readings from different sensors.
    func write(_ reading: GlucoseReading) async throws {
        let quantity = HKQuantity(unit: Self.mgDL, doubleValue: reading.valueMgDl)
        let sample = HKQuantitySample(
            type: Self.glucoseType,
            quantity: quantity,
            start: reading.timestamp,
            end: reading.timestamp,
            metadata: [
                HKMetadataKeyWasUserEntered: false,
                "com.threecee.loop.sensorId": reading.sensorId,
                "com.threecee.loop.trend": reading.trend.rawValue,
            ]
        )
        try await store.save(sample)
    }
}
