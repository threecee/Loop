//
//  AlgorithmStateSnapshotEmitter.swift
//  Loop
//
// builds an AlgorithmStateSnapshot from current Loop state and pushes
//  it over the existing PhoneWatchTransport. Called from
//  LoopDataManager.loopAlgorithmRunnerDidFinishLoop after every successful
//  iteration.
//
// delivery routes through updateApplicationContext
//  (latest-only, intentionally overwrites) rather than transferUserInfo
//  (FIFO queue, can backlog when watch offline). Snapshots are coalescable
//  state — the watch only needs the freshest payload at takeover, so the
//  OS overwriting older snapshots is the correct behavior.
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
    /// routes through `updateApplicationContext` (latest-only,
    /// intentionally overwrites). `transferUserInfo` (via `queueMessage`) is
    /// reserved for non-coalescable events (modeSwitch, pairingHandoff,
    /// manual user actions). AlgorithmStateSnapshot is coalescable state —
    /// the watch only ever needs the freshest snapshot at takeover, so
    /// allowing the OS to overwrite older queued snapshots prevents backlogs
    /// when the watch is offline (locked / on charger / off-wrist) and
    /// guarantees the watch reads the freshest payload immediately on resume.
    func send(_ message: PhoneWatchMessage) {
        sendApplicationContext(message)
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
