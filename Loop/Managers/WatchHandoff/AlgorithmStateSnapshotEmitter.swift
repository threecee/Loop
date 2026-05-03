//
//  AlgorithmStateSnapshotEmitter.swift
//  Loop
//
//  B.8: builds an AlgorithmStateSnapshot from current Loop state and pushes
//  it over the existing PhoneWatchTransport. Called from
//  LoopDataManager.loopAlgorithmRunnerDidFinishLoop after every successful
//  iteration. Fire-and-forget; transport handles immediate vs queued delivery.
//

import Foundation
import LoopKit
import OmniBLE

/// Minimal transport interface so the emitter can be unit-tested with a
/// capturing fake without dragging in a real WCSession.
protocol SnapshotTransport: AnyObject {
    func send(_ message: PhoneWatchMessage)
}

/// Conformance on the concrete `WCSessionPhoneWatchTransport` (Swift forbids
/// declaring `extension <Protocol>: <Protocol>`, so we adopt on the class
/// instead — production code passes the concrete transport here).
extension WCSessionPhoneWatchTransport: SnapshotTransport {
    func send(_ message: PhoneWatchMessage) {
        sendMessage(message, reply: nil, onError: { _ in })
    }
}

final class AlgorithmStateSnapshotEmitter {
    /// All the state the emitter needs to assemble one snapshot. The provider
    /// closure returns nil when state isn't yet available (e.g. very early
    /// launch); the emit call is a no-op in that case.
    struct State {
        let iterationDate: Date
        let glucoseSamples: [StoredGlucoseSample]
        let doseHistory: [DoseEntry]
        let carbEntries: [StoredCarbEntry]
        let pumpStatus: PumpStatusSnapshot
        let activeOverride: TemporaryScheduleOverride?
    }

    private let transport: SnapshotTransport
    private let now: () -> Date
    private let stateProvider: () -> State?

    init(transport: SnapshotTransport,
         now: @escaping () -> Date = { Date() },
         stateProvider: @escaping () -> State?) {
        self.transport = transport
        self.now = now
        self.stateProvider = stateProvider
    }

    func emit() {
        guard let state = stateProvider() else { return }
        let snapshot = AlgorithmStateSnapshot(
            snapshotID: UUID(),
            createdAt: now(),
            phoneIterationDate: state.iterationDate,
            glucoseSamples: state.glucoseSamples,
            doseHistory: state.doseHistory,
            carbEntries: state.carbEntries,
            pumpStatus: state.pumpStatus,
            activeOverride: state.activeOverride
        )
        transport.send(.algorithmStateSnapshot(snapshot))
    }
}
