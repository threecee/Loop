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
import LoopKit  // B.6: for `PumpManager` (forwarded accessor)
import OmniBLE
import Combine
import os.log

@MainActor
final class HandoffOrchestrator: ObservableObject {

    /// B.5 Issue #5: shared accessor populated by ExtensionDelegate at launch.
    /// Read by the watch's `PhoneWatchSessionCoordinator` to evaluate
    /// split-brain (i.e. compare local handoffState.currentOwner against
    /// the inbound heartbeat's claimedOwner).
    static weak var shared: HandoffOrchestrator?

    /// B.5 Issue #1: log channel for command-gate effect transitions and
    /// split-brain detection.
    private let log = OSLog(category: "HandoffOrchestrator")

    @Published private(set) var handoffState: HandoffState
    @Published var settings: HandoffSettings

    /// User defaults used for settings persistence. Mutable for tests; production
    /// uses the App Group suite (group.com.threecee.loop.LoopGroup).
    var userDefaults: UserDefaults

    private var coordinator: PhoneWatchSessionCoordinator
    private var stateMachine: HandoffStateMachine
    private var policyEngine: HandoffPolicyEngine
    private var shadowScheduler: ShadowStateScheduler

    private var cancellables: Set<AnyCancellable> = []
    private var scheduledTimers: [UUID: Task<Void, Never>] = [:]

    /// B.4 Issue #2: 60s debounce timer for marking phone-stable. When
    /// reachability flips on, we wait 60s before declaring "stable since",
    /// to avoid flapping during BLE reconnect storms. If reachability flips
    /// off in the interim, the timer is cancelled and stable-since is cleared.
    private var phoneStableDebounce: Task<Void, Never>?

    /// B.4 Issue #2: debounce window matches HandoffPolicyEngine.absenceThreshold (60s).
    /// Tests can override via the optional `phoneStableDebounceOverride` init parameter.
    private static let defaultPhoneStableDebounceSeconds: TimeInterval = 60
    private let phoneStableDebounceSeconds: TimeInterval

    // B.2.e: BLE ownership coordinator. Exposed (internal) so the
    // PhoneWatchSessionCoordinator's split-brain detection (B.5 Issue #5)
    // and the orchestrator unit tests (B.5 Issue #1) can read/write the
    // commandsAllowed flag directly.
    let ownership: OmniBLEOwnership

    /// B.2.e: replaces the previous `lastReceivedPayload` field — accessor
    /// now forwards to ownership's cache (single source of truth).
    var cachedPayload: OmniBLEHandoffPayload? { ownership.cachedPayload }

    /// B.6: forwarded accessor for the lazily-constructed OmniBLEPumpManager,
    /// typed as `PumpManager` (LoopKit) since that's what the algorithm enacts on.
    /// Returns nil until the first `.watchDriver` transition triggers
    /// `OmniBLEOwnership.setPumpManager(_:)`. The runtime cast
    /// `OmniBLEPodOwner? -> PumpManager?` is safe because the concrete type is
    /// always `OmniBLEPumpManager`, which conforms to both protocols.
    var pumpManager: PumpManager? { ownership.pumpManager as? PumpManager }

    /// Forwarded from the state machine. Capped at 10 (state machine enforces).
    var transitionLog: [HandoffTransitionRecord] {
        stateMachine.transitionLog
    }

    init(coordinator: PhoneWatchSessionCoordinator,
         stateMachine: HandoffStateMachine,
         policyEngine: HandoffPolicyEngine,
         shadowScheduler: ShadowStateScheduler,
         userDefaults: UserDefaults = UserDefaults(suiteName: HandoffSettings.appGroupIdentifier)
            ?? UserDefaults.standard,
         phoneStableDebounceOverride: TimeInterval? = nil) {
        self.coordinator = coordinator
        self.stateMachine = stateMachine
        self.policyEngine = policyEngine
        self.shadowScheduler = shadowScheduler
        self.userDefaults = userDefaults
        self.handoffState = stateMachine.state
        self.settings = HandoffSettings.load(from: userDefaults)
        self.ownership = OmniBLEOwnership(
            role: .watch,
            pumpManager: nil,    // lazy: built on first .watchDriver transition
            appGroupDefaults: userDefaults,
            initialState: stateMachine.state
        )
        self.phoneStableDebounceSeconds = phoneStableDebounceOverride
            ?? Self.defaultPhoneStableDebounceSeconds
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

        // B.4 Issue #2: seed initial owner. The watch starts assuming phone
        // is driving until it receives a handoff or detects absence.
        policyEngine.markCurrentOwner(.phone)

        // B.4 Issue #2: subscribe to reachability changes. Flip-on starts a
        // 60s debounce; flip-off immediately clears stable-since.
        coordinator.$isCounterpartReachable
            .removeDuplicates()
            .sink { [weak self] reachable in
                guard let self else { return }
                self.handleReachabilityChanged(reachable)
            }
            .store(in: &cancellables)
    }

    func stop() {
        coordinator.onHandoffMessage = nil
        policyEngine.stop()
        shadowScheduler.stop()
        scheduledTimers.values.forEach { $0.cancel() }
        scheduledTimers.removeAll()
        phoneStableDebounce?.cancel()
        phoneStableDebounce = nil
        cancellables.removeAll()
    }

    func userRequestHandoff(to target: HandoffOwner) {
        // B.4 Issue #2: record the user activity so the policy engine's
        // 30s user-activity-quiet window kicks in.
        policyEngine.markUserInteractedAt(Date())
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
                ownership.cachePayload(decoded)   // B.2.e (replaces lastReceivedPayload assignment)
                // B.4 Issue #2: mark cached pod state freshness so the policy
                // engine's takeover safety gate knows the payload is recent.
                policyEngine.markCachedPodStateAge(Date())
            }
        case .settingsSync:
            // Handled upstream by PhoneWatchSessionCoordinator (stored in
            // WatchSettingsCache.shared). No state-machine event to fire.
            break
        }
    }

    /// Test-only injection point.
    func injectStateMachine(_ machine: HandoffStateMachine) {
        stateMachine = machine
        handoffState = machine.state
    }

    /// B.4 Issue #2: reachability change handler. On flip-on, schedule a 60s
    /// debounce → mark phone stable. On flip-off, cancel the debounce and
    /// clear stable-since immediately.
    @MainActor
    private func handleReachabilityChanged(_ reachable: Bool) {
        phoneStableDebounce?.cancel()
        if !reachable {
            policyEngine.markPhoneStableSince(nil)
            return
        }
        let debounce = phoneStableDebounceSeconds
        phoneStableDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Re-check reachability after the actor hop: defends against the
                // window where reachability flipped off during the sleep but the
                // off-callback hasn't been processed yet.
                if self.coordinator.isReachable {
                    self.policyEngine.markPhoneStableSince(Date())
                }
            }
        }
    }

    /// B.5 Issue #1: surfaced (internal) so unit tests can directly invoke
    /// the side-effect set under test (e.g. `.stopIssuingPodCommands`)
    /// without having to drive a full state-machine event sequence.
    func execute(_ effects: [HandoffSideEffect]) {
        for effect in effects {
            switch effect {
            case .sendModeSwitch(let ms):
                coordinator.sendModeSwitch(ms)
            case .sendPairingHandoff(let ph):
                coordinator.sendPairingHandoff(fillPayload(ph))   // B.2.e
            case .sendSettingsSync:
                // Settings sync is phone → watch only. The watch-side state
                // machine never emits this; no-op for completeness.
                break
            case .scheduleTimeout(let id, let delay):
                scheduleTimeout(id: id, after: delay)
            case .stopIssuingPodCommands:
                // B.5 Issue #1: gate pod commands during handoff transitions.
                ownership.commandsAllowed = false
                log.default("commandsAllowed=false (handoff in progress)")
            case .resumeIssuingPodCommands:
                ownership.commandsAllowed = true
                log.default("commandsAllowed=true (handoff complete)")
            case .recordTransitionInLog:
                break  // state machine maintains its own log
            case .notifyUI(let state):
                // B.6 race hardening: do all dependent-state mutations BEFORE
                // assigning handoffState. The @Published handoffState fires
                // a Combine sink (in ExtensionDelegate) that calls into
                // WatchAlgorithmBootstrap, which reads ownership.pumpManager.
                // If we set handoffState first, the sink could (depending
                // on scheduler) observe the lazy-init NOT having happened
                // yet, causing the algorithm driver to be constructed with
                // pumpManager: nil and suppressing the first dose.
                //
                // Order: lazy-init pump manager → ownership.update → policy
                // engine mark → publish handoffState (triggers downstream).

                // B.2.e: lazy-instantiate OmniBLEPumpManager on first .watchDriver
                if case .watchDriver = state, ownership.pumpManager == nil {
                    let pm = OmniBLEPumpManager(state: .watchSideDefault)
                    ownership.setPumpManager(pm)
                }
                ownership.update(state: state)   // B.2.e
                // B.4 Issue #2: mark current owner on every state transition
                // so the policy engine knows whose perspective to evaluate from.
                if let owner = state.currentOwner {
                    policyEngine.markCurrentOwner(owner)
                }
                // Publish handoffState LAST — triggers downstream sinks
                // that depend on the now-current ownership + policy state.
                handoffState = state
            }
        }
    }

    /// B.2.e: Fills the pairing-handoff payload with the current PodState
    /// (serialized via OmniBLEHandoffPayload's PropertyListSerialization helper)
    /// before the message goes out over WCSession.
    private func fillPayload(_ template: PhoneWatchPairingHandoff) -> PhoneWatchPairingHandoff {
        guard let pumpManager = ownership.pumpManager as? OmniBLEPumpManager,
              let podState = pumpManager.state.podState
        else {
            return template   // empty payload — counterpart will see no LTK
        }
        do {
            let payload = try OmniBLEHandoffPayload(podState: podState)
            let serialized = try payload.encoded()
            return PhoneWatchPairingHandoff(
                protocolVersion: template.protocolVersion,
                sentAt: template.sentAt,
                podId: template.podId,
                pairingPayload: serialized,
                validUntil: template.validUntil,
                transitionId: template.transitionId
            )
        } catch {
            return template
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
