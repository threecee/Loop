//
//  HandoffOrchestrator.swift
//  LoopWatchApp (watchOS)
//
//  Glue between B.2.c's PhoneWatchSessionCoordinator and B.2.d's
//  HandoffStateMachine + HandoffPolicyEngine + ShadowStateScheduler.
//  Executes HandoffSideEffect values returned by the state machine.
//
//  Design choice (per plan Task 3.2 "transitionLog forwarding"): we expose
//  `transitionLog` as a computed property forwarding to the state machine.
//  Single source of truth — no duplication. Visible to UI via @ObservedObject
//  re-render when handoffState changes (the log advances on every state
//  transition we care to display).
//

import Foundation
import OmniBLE
import Combine

@MainActor
final class HandoffOrchestrator: ObservableObject {

    @Published private(set) var handoffState: HandoffState
    @Published var settings: HandoffSettings

    /// User defaults used for settings persistence. Mutable for tests; production
    /// uses the App Group suite (group.com.threecee.loopGroup).
    var userDefaults: UserDefaults

    private var coordinator: PhoneWatchSessionCoordinator
    private var stateMachine: HandoffStateMachine
    private var policyEngine: HandoffPolicyEngine
    private var shadowScheduler: ShadowStateScheduler

    private var cancellables: Set<AnyCancellable> = []
    private var scheduledTimers: [UUID: Task<Void, Never>] = [:]
    private var lastReceivedPayload: OmniBLEHandoffPayload?

    /// Forwarded from the state machine. Capped at 10 (state machine enforces).
    var transitionLog: [HandoffTransitionRecord] {
        stateMachine.transitionLog
    }

    init(coordinator: PhoneWatchSessionCoordinator,
         stateMachine: HandoffStateMachine,
         policyEngine: HandoffPolicyEngine,
         shadowScheduler: ShadowStateScheduler,
         userDefaults: UserDefaults = UserDefaults(suiteName: HandoffSettings.appGroupIdentifier)
            ?? UserDefaults.standard) {
        self.coordinator = coordinator
        self.stateMachine = stateMachine
        self.policyEngine = policyEngine
        self.shadowScheduler = shadowScheduler
        self.userDefaults = userDefaults
        self.handoffState = stateMachine.state
        self.settings = HandoffSettings.load(from: userDefaults)
    }

    func start() {
        // Wire incoming-message forwarding from coordinator to state machine.
        coordinator.onHandoffMessage = { [weak self] message in
            Task { @MainActor in self?.handleIncoming(message: message) }
        }
        // Wire shadow scheduler's fire closure to state machine.
        shadowScheduler.setFire { [weak self] in
            guard let self else { return }
            let effects = self.stateMachine.handle(.shadowStateRefreshDue)
            self.execute(effects)
        }
        policyEngine.start()
        shadowScheduler.start()
    }

    func stop() {
        coordinator.onHandoffMessage = nil
        policyEngine.stop()
        shadowScheduler.stop()
        scheduledTimers.values.forEach { $0.cancel() }
        scheduledTimers.removeAll()
    }

    func userRequestHandoff(to target: HandoffOwner) {
        let effects = stateMachine.handle(.userRequestedHandoff(target: target))
        execute(effects)
    }

    func updateSettings(_ new: HandoffSettings) {
        settings = new
        try? new.save(to: userDefaults)
        policyEngine.updateSettings(new)
    }

    func dismissRecovering() {
        let effects = stateMachine.handle(.manualRecoveryDismiss)
        execute(effects)
    }

    func handleIncoming(message: PhoneWatchMessage) {
        switch message {
        case .heartbeat:
            return  // coordinator handles heartbeats; not state-machine-relevant
        case .modeSwitch(let ms):
            execute(stateMachine.handle(.incomingModeSwitch(ms)))
        case .pairingHandoff(let ph):
            execute(stateMachine.handle(.incomingPairingHandoff(ph)))
            // Cache the payload for future takeover.
            if let decoded = try? JSONDecoder().decode(OmniBLEHandoffPayload.self,
                                                       from: ph.pairingPayload) {
                lastReceivedPayload = decoded
            }
        }
    }

    /// Most-recently received OmniBLEHandoffPayload, if any. Consumed by B.2.e
    /// when actually taking over the BLE session.
    var cachedPayload: OmniBLEHandoffPayload? { lastReceivedPayload }

    /// Test-only injection point.
    func injectStateMachine(_ machine: HandoffStateMachine) {
        stateMachine = machine
        handoffState = machine.state
    }

    private func execute(_ effects: [HandoffSideEffect]) {
        for effect in effects {
            switch effect {
            case .sendModeSwitch(let ms):
                coordinator.sendModeSwitch(ms)
            case .sendPairingHandoff(let ph):
                // Replace the state machine's placeholder pairingPayload with a
                // real OmniBLEHandoffPayload built from current PodState. B.2.e
                // wires up an actual PodState provider; for B.2.d we ship an
                // empty/default payload (UI is the verification surface).
                coordinator.sendPairingHandoff(ph)
            case .scheduleTimeout(let id, let delay):
                scheduleTimeout(id: id, after: delay)
            case .stopIssuingPodCommands:
                NSLog("HandoffOrchestrator: stopIssuingPodCommands (B.2.e wires this up)")
            case .resumeIssuingPodCommands:
                NSLog("HandoffOrchestrator: resumeIssuingPodCommands (B.2.e wires this up)")
            case .recordTransitionInLog:
                break  // state machine maintains its own log
            case .notifyUI(let state):
                handoffState = state
            }
        }
    }

    private func scheduleTimeout(id: UUID, after delay: TimeInterval) {
        scheduledTimers[id]?.cancel()
        scheduledTimers[id] = Task { [weak self, delay, id] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.execute(self.stateMachine.handle(.transitionDeadlineReached(transitionId: id)))
            }
        }
    }
}
