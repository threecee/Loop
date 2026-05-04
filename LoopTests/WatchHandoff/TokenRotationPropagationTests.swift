//
//  TokenRotationPropagationTests.swift
//  LoopTests
//
//  B.11.2: end-to-end propagation. Rotating the phone (or watch) APNs
//  token in the App Group APNsTokenStore causes the next call to
//  HandoffOrchestrator.buildSignedRendezvous() to carry the rotated
//  token in the resulting DriverTokenRendezvous payload, with a
//  recomputed HMAC-SHA256 signature. This exercises the B.11.0
//  apnsTokenPublish persistence + the B.11.2 rendezvous build path
//  together.
//
//  Production splice into Nightscout devicestatus
//  (loop.testingDetails.driverToken) is in NightscoutService and is
//  out of scope for this slice — see DONE_WITH_CONCERNS in B.11.2
//  closeout. These tests assert the producer side is correct so that
//  the consumer-side splice (B.11.2.1) is a mechanical follow-up.
//

import XCTest
import OmniBLE
@testable import Loop

@MainActor
final class TokenRotationPropagationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: APNsTokenStore!
    private var fixedNow: Date!

    override func setUp() async throws {
        let suiteName = "TokenRotationPropagationTests-\(UUID().uuidString)"
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

    private func savePhoneToken(_ raw: Data, sentAt: Date? = nil) {
        store.save(APNsTokenPublication(
            protocolVersion: 1,
            sentAt: sentAt ?? fixedNow,
            role: .phone,
            token: raw,
            expiresAt: fixedNow.addingTimeInterval(86_400 * 30)
        ))
    }

    private func saveWatchToken(_ raw: Data, sentAt: Date? = nil) {
        store.save(APNsTokenPublication(
            protocolVersion: 1,
            sentAt: sentAt ?? fixedNow,
            role: .watch,
            token: raw,
            expiresAt: fixedNow.addingTimeInterval(86_400 * 30)
        ))
    }

    // MARK: - Phone-token rotation (own-token rotation by phone driver)

    func test_phoneTokenRotation_propagatesToNextRendezvous() throws {
        // Initial seeded tokens.
        let phoneV1 = Data("phone-v1".utf8)
        let watchV1 = Data("watch-v1".utf8)
        savePhoneToken(phoneV1)
        saveWatchToken(watchV1, sentAt: fixedNow.addingTimeInterval(-300))  // peer published 5min ago

        let orchestrator = makeOrchestrator(role: .phone, apiSecret: "secret")
        // Default state is .phoneDriver.
        let first = try XCTUnwrap(orchestrator.buildSignedRendezvous())
        XCTAssertEqual(first.phone.token, phoneV1.base64EncodedString())
        XCTAssertEqual(first.watch.token, watchV1.base64EncodedString())
        XCTAssertEqual(first.currentDriver, .phone)
        XCTAssertTrue(first.verify(with: "secret"))

        // Simulate didRegisterForRemoteNotificationsWithDeviceToken firing
        // again with a rotated token: the iOS app delegate writes the new
        // publication to APNsTokenStore + posts apnsTokenPublish via
        // WCSession to the watch.
        let phoneV2 = Data("phone-v2".utf8)
        savePhoneToken(phoneV2)

        let second = try XCTUnwrap(orchestrator.buildSignedRendezvous())
        XCTAssertEqual(second.phone.token, phoneV2.base64EncodedString(),
                       "Rotated phone token must propagate to next rendezvous")
        XCTAssertEqual(second.watch.token, watchV1.base64EncodedString(),
                       "Watch token unchanged")
        XCTAssertTrue(second.verify(with: "secret"))
        XCTAssertNotEqual(first.signature, second.signature,
                          "Signature must change when canonical message changes (token rotated)")
    }

    // MARK: - Watch-token rotation (peer rotation arriving over WCSession)

    func test_watchTokenRotation_propagatesViaAppGroupToPhoneDriver() throws {
        let phoneV1 = Data("phone-v1".utf8)
        let watchV1 = Data("watch-v1".utf8)
        savePhoneToken(phoneV1)
        saveWatchToken(watchV1, sentAt: fixedNow.addingTimeInterval(-300))

        let orchestrator = makeOrchestrator(role: .phone, apiSecret: "secret")
        let first = try XCTUnwrap(orchestrator.buildSignedRendezvous())
        XCTAssertEqual(first.watch.token, watchV1.base64EncodedString())

        // Simulate apnsTokenPublish(role: .watch, token: ...) arriving via
        // WCSession from the watch — production handler writes the new
        // publication to the same App Group APNsTokenStore.
        let watchV2 = Data("watch-v2".utf8)
        saveWatchToken(watchV2, sentAt: fixedNow.addingTimeInterval(-10))

        let second = try XCTUnwrap(orchestrator.buildSignedRendezvous())
        XCTAssertEqual(second.watch.token, watchV2.base64EncodedString(),
                       "Rotated peer (watch) token must propagate to phone driver's rendezvous")
        XCTAssertEqual(second.phone.token, phoneV1.base64EncodedString())
        XCTAssertNotEqual(first.signature, second.signature)
    }

    // MARK: - Watch-driver rotation case (symmetric)

    func test_phoneTokenRotation_propagatesToWatchDriverRendezvous() throws {
        let phoneV1 = Data("phone-v1".utf8)
        let watchV1 = Data("watch-v1".utf8)
        savePhoneToken(phoneV1, sentAt: fixedNow.addingTimeInterval(-300))
        saveWatchToken(watchV1)

        let orchestrator = makeOrchestrator(role: .watch, apiSecret: "secret")
        // Force watch-driver state.
        orchestrator.execute([.notifyUI(state: .watchDriver)])
        XCTAssertTrue(orchestrator.isCurrentDriver)

        let first = try XCTUnwrap(orchestrator.buildSignedRendezvous())
        XCTAssertEqual(first.currentDriver, .watch)
        XCTAssertEqual(first.phone.token, phoneV1.base64EncodedString())

        // Phone rotates (apnsTokenPublish .phone arrives over WCSession,
        // watch persists to the same App Group).
        let phoneV2 = Data("phone-v2".utf8)
        savePhoneToken(phoneV2, sentAt: fixedNow.addingTimeInterval(-5))

        let second = try XCTUnwrap(orchestrator.buildSignedRendezvous())
        XCTAssertEqual(second.phone.token, phoneV2.base64EncodedString(),
                       "Rotated peer (phone) token must propagate to watch driver's rendezvous")
        XCTAssertEqual(second.watch.token, watchV1.base64EncodedString())
        XCTAssertNotEqual(first.signature, second.signature)
    }
}
