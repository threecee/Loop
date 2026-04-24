import XCTest
import HealthKit
@testable import WatchApp_Extension

final class HealthKitWriterTests: XCTestCase {

    func testWriteSuccess() async throws {
        let store = MockHealthStore()
        store.saveResult = .success(())
        let writer = HealthKitWriter(store: store)

        let reading = GlucoseReading(valueMgDl: 120, timestamp: Date(), trend: .flat, sensorId: "X")
        try await writer.write(reading)

        XCTAssertEqual(store.savedSamples.count, 1)
        let sample = store.savedSamples[0] as? HKQuantitySample
        XCTAssertNotNil(sample)
        XCTAssertEqual(sample?.quantity.doubleValue(for: HKUnit(from: "mg/dL")), 120)
    }

    func testWriteAuthDeniedThrows() async {
        let store = MockHealthStore()
        store.saveResult = .failure(NSError(domain: HKErrorDomain, code: HKError.errorAuthorizationDenied.rawValue))
        let writer = HealthKitWriter(store: store)

        let reading = GlucoseReading(valueMgDl: 120, timestamp: Date(), trend: .flat, sensorId: "X")
        do {
            try await writer.write(reading)
            XCTFail("expected error")
        } catch {
            // Expected
        }
    }

    func testRequestAuthorization() async throws {
        let store = MockHealthStore()
        store.authResult = .success(())
        let writer = HealthKitWriter(store: store)

        try await writer.requestAuthorization()

        // Asserts the contract rather than the exact size of the set, so adding
        // future write types doesn't break this test:
        // - we always ask to share the diabetes triad
        XCTAssertTrue(store.requestedTypes.contains(HKQuantityType(.bloodGlucose)))
        XCTAssertTrue(store.requestedTypes.contains(HKQuantityType(.insulinDelivery)))
        XCTAssertTrue(store.requestedTypes.contains(HKQuantityType(.dietaryCarbohydrates)))
        // - and we ask to read at least the headline watch metrics
        XCTAssertTrue(store.requestedReadTypes.contains(HKQuantityType(.heartRate)))
        XCTAssertTrue(store.requestedReadTypes.contains(HKCategoryType(.sleepAnalysis)))
        XCTAssertTrue(store.requestedReadTypes.contains(HKQuantityType(.activeEnergyBurned)))
    }
}

// Minimal mock conforming to the protocol we define on HealthKitWriter.
final class MockHealthStore: HealthStoreProtocol {
    var savedSamples: [HKSample] = []
    var requestedTypes: Set<HKSampleType> = []
    var requestedReadTypes: Set<HKObjectType> = []
    var saveResult: Result<Void, Error> = .success(())
    var authResult: Result<Void, Error> = .success(())

    func save(_ sample: HKSample) async throws {
        savedSamples.append(sample)
        try saveResult.get()
    }

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        requestedTypes.formUnion(toShare)
        requestedReadTypes.formUnion(read)
        try authResult.get()
    }
}
