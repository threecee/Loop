//
//  DriverTokenNightscoutSpliceTests.swift
//  LoopTests
//
//  B.11.2.1: end-to-end integration test for the consumer-side splice
//  of the driver-token rendezvous (B.11.2 producer) into Nightscout
//  devicestatus uploads.
//
//  This test exercises the full pipeline:
//
//      HandoffOrchestrator.buildSignedRendezvous()
//          -> .dictionaryRepresentation
//          -> NightscoutService.driverTokenProvider closure (Loop wiring)
//          -> StoredDosingDecision.deviceStatus(driverTokenDict:)
//          -> NightscoutKit.LoopStatus.testingDetails["driverToken"]
//          -> JSON payload at path `loop.testingDetails.driverToken`
//
//  The producer side is covered by OmniBLETests/HandoffOrchestratorTests
//  and OmniBLETests/DriverTokenRendezvousTests (B.11.2). The
//  NightscoutService boundary is covered by
//  NightscoutServiceKitTests/StoredDosingDecisionDriverTokenTests
//  (B.11.2.1). This file is the third leg: it wires the Loop-side
//  closure that production uses (LoopAppManager) and asserts the JSON
//  shape NightscoutClient would serialize.
//

import XCTest
import HealthKit
import LoopKit
import NightscoutKit
import NightscoutServiceKit
import OmniBLE
@testable import Loop

@MainActor
final class DriverTokenNightscoutSpliceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: APNsTokenStore!
    private var fixedNow: Date!

    override func setUp() async throws {
        let suiteName = "DriverTokenNightscoutSpliceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = APNsTokenStore(defaults: defaults)
        fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
    }

    private func makeOrchestrator(role: HandoffRole, apiSecret: String) -> HandoffOrchestrator {
        let stack = HandoffStack.assemble(
            role: role,
            appGroupDefaults: defaults,
            nightscoutAPISecretProvider: { apiSecret },
            clock: { [unowned self] in self.fixedNow }
        )
        return stack.orchestrator
    }

    private func savePhoneToken(_ raw: Data) {
        store.save(APNsTokenPublication(
            protocolVersion: 1,
            sentAt: fixedNow,
            role: .phone,
            token: raw,
            expiresAt: fixedNow.addingTimeInterval(86_400 * 30)
        ))
    }

    private func saveWatchToken(_ raw: Data) {
        store.save(APNsTokenPublication(
            protocolVersion: 1,
            sentAt: fixedNow.addingTimeInterval(-300),
            role: .watch,
            token: raw,
            expiresAt: fixedNow.addingTimeInterval(86_400 * 30)
        ))
    }

    // The same closure shape LoopAppManager assigns to
    // `NightscoutService.driverTokenProvider` at boot. Kept inline so the
    // test exercises the production wiring contract directly.
    private func driverTokenProvider(orchestrator: HandoffOrchestrator) -> () -> [String: Any]? {
        return { [weak orchestrator] in
            return orchestrator?.buildSignedRendezvous()?.dictionaryRepresentation
        }
    }

    // MARK: - JSON payload integration

    func test_uploadPayload_carriesRendezvousAtSpecPath() throws {
        // Seed both tokens so the orchestrator builds a complete rendezvous.
        savePhoneToken(Data("phone-v1".utf8))
        saveWatchToken(Data("watch-v1".utf8))
        let orchestrator = makeOrchestrator(role: .phone, apiSecret: "secret")
        let provider = driverTokenProvider(orchestrator: orchestrator)

        // Simulate the NightscoutService boot wiring + a single dosing
        // decision being mapped to a DeviceStatus the same way
        // NightscoutService.uploadDosingDecisionData(_:completion:) does.
        let decision = StoredDosingDecision(reason: "loop")
        let driverDict = provider()
        let device = decision.deviceStatus(automaticDoseDecision: nil,
                                           driverTokenDict: driverDict)

        // Serialize via the same JSONSerialization path NightscoutClient
        // uses for upload bodies. Validate the rendezvous lands at the
        // spec-defined JSON path `loop.testingDetails.driverToken`.
        let payload = device.dictionaryRepresentation
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let loop = try XCTUnwrap(parsed["loop"] as? [String: Any])
        let testingDetails = try XCTUnwrap(loop["testingDetails"] as? [String: Any])
        let driverToken = try XCTUnwrap(testingDetails["driverToken"] as? [String: Any])

        XCTAssertEqual(driverToken["currentDriver"] as? String, "phone")
        XCTAssertNotNil(driverToken["signature"], "Signed rendezvous must carry HMAC signature")
        XCTAssertNotNil(driverToken["timestamp"])

        let phone = try XCTUnwrap(driverToken["phone"] as? [String: Any])
        XCTAssertEqual(phone["token"] as? String, Data("phone-v1".utf8).base64EncodedString())

        let watch = try XCTUnwrap(driverToken["watch"] as? [String: Any])
        XCTAssertEqual(watch["token"] as? String, Data("watch-v1".utf8).base64EncodedString())
    }

    func test_uploadPayload_omitsTestingDetailsWhenNotDriver() throws {
        // No tokens persisted -> orchestrator returns nil from
        // buildSignedRendezvous() -> provider returns nil -> deviceStatus
        // omits the testingDetails field entirely. This ensures that
        // when the phone is not currently the driver (or hasn't yet
        // exchanged tokens with the peer), caretakers don't see a stale
        // `loop.testingDetails.driverToken` entry.
        let orchestrator = makeOrchestrator(role: .phone, apiSecret: "secret")
        let provider = driverTokenProvider(orchestrator: orchestrator)
        XCTAssertNil(provider(), "Provider must return nil when no rendezvous is available")

        let decision = StoredDosingDecision(reason: "loop")
        let device = decision.deviceStatus(automaticDoseDecision: nil,
                                           driverTokenDict: provider())

        let payload = device.dictionaryRepresentation
        let loop = try XCTUnwrap(payload["loop"] as? [String: Any])
        XCTAssertNil(loop["testingDetails"],
                     "When provider returns nil, testingDetails must be omitted (not stale-cached)")
    }

    func test_uploadPayload_signatureVerifiesAgainstApiSecret() throws {
        // Round-trip: take the rendezvous from the JSON payload, decode
        // it back into a DriverTokenRendezvous via its Codable form, and
        // verify the signature against the same api-secret the
        // orchestrator was wired with. This proves the JSON-shape
        // contract is symmetric with the producer-side spec.
        savePhoneToken(Data("phone-v1".utf8))
        saveWatchToken(Data("watch-v1".utf8))
        let orchestrator = makeOrchestrator(role: .phone, apiSecret: "secret")
        let provider = driverTokenProvider(orchestrator: orchestrator)

        let decision = StoredDosingDecision(reason: "loop")
        let device = decision.deviceStatus(automaticDoseDecision: nil,
                                           driverTokenDict: provider())
        let payload = device.dictionaryRepresentation
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let loop = try XCTUnwrap(parsed["loop"] as? [String: Any])
        let testingDetails = try XCTUnwrap(loop["testingDetails"] as? [String: Any])
        let driverToken = try XCTUnwrap(testingDetails["driverToken"] as? [String: Any])

        // Reconstruct DriverTokenRendezvous from JSON via re-encoding the
        // dict to JSON then JSONDecoder. This exercises the same
        // Codable round-trip a caretaker app would perform when reading
        // the rendezvous out of Nightscout devicestatus.
        let driverData = try JSONSerialization.data(withJSONObject: driverToken)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rendezvous = try decoder.decode(DriverTokenRendezvous.self, from: driverData)

        XCTAssertEqual(rendezvous.currentDriver, .phone)
        XCTAssertEqual(rendezvous.phone.token, Data("phone-v1".utf8).base64EncodedString())
        XCTAssertEqual(rendezvous.watch.token, Data("watch-v1".utf8).base64EncodedString())
        XCTAssertTrue(rendezvous.verify(with: "secret"),
                      "Caretaker app round-trip must verify against the same api-secret")
        XCTAssertFalse(rendezvous.verify(with: "wrong-secret"),
                       "Wrong api-secret must fail verification")
    }
}
