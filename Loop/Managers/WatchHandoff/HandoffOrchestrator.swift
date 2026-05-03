//
//  HandoffOrchestrator.swift
//  Loop (iOS)
//
//  Glue between B.2.c's PhoneWatchSessionCoordinator and B.2.d's
//  HandoffStateMachine + HandoffPolicyEngine + ShadowStateScheduler.
//  Executes HandoffSideEffect values returned by the state machine.
//  Parallel to LoopWatchApp's HandoffOrchestrator.
//

import Foundation
import OmniBLE
import Combine
import os.log

@MainActor
final class HandoffOrchestrator: ObservableObject {

    /// Shared accessor populated by LoopAppManager at launch. SwiftUI views
    /// read this to observe handoff state.
    static weak var shared: HandoffOrchestrator?

    @Published private(set) var handoffState: HandoffState
    @Published var settings: HandoffSettings

    var userDefaults: UserDefaults

    /// B.5 Issue #1: log channel for command-gate effect transitions.
    private let log = OSLog(category: "HandoffOrchestrator")

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

    /// B.5.2 Issue #3b: token returned by the closure-based observer for
    /// `.NSSystemTimeZoneDidChange`. Held so `deinit` can remove it explicitly
    /// (closure observers are not removed by `removeObserver(self)` because the
    /// observer object is the returned token, not `self`). App-lifetime scoped
    /// — `deinit` only fires at app termination in production.
    private var systemTZObserver: NSObjectProtocol?

    /// B.4 Issue #2: debounce window matches HandoffPolicyEngine.absenceThreshold (60s).
    /// Tests can override via the optional `phoneStableDebounceOverride` init parameter.
    private static let defaultPhoneStableDebounceSeconds: TimeInterval = 60
    private let phoneStableDebounceSeconds: TimeInterval

    // B.2.e: BLE ownership coordinator. Exposed (internal) so the
    // PhoneWatchSessionCoordinator's split-brain detection (B.5 Issue #5)
    // and the orchestrator unit tests (B.5 Issue #1) can read/write the
    // commandsAllowed flag directly.
    let ownership: OmniBLEOwnership

    /// B.3.a Phase 6: returns the current settings snapshot for sync to the
    /// watch. Injected at init via closure so the orchestrator stays decoupled
    /// from LoopDataManager / ServicesManager. Returns nil when not yet ready.
    private let settingsSyncProvider: (() -> PhoneWatchSettingsSync?)?

    /// B.2.e: replaces the previous `lastReceivedPayload` field — accessor
    /// now forwards to ownership's cache (single source of truth).
    var cachedPayload: OmniBLEHandoffPayload? { ownership.cachedPayload }

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
         pumpManager: OmniBLEPodOwner? = nil,
         settingsSyncProvider: (() -> PhoneWatchSettingsSync?)? = nil,
         phoneStableDebounceOverride: TimeInterval? = nil) {
        self.coordinator = coordinator
        self.stateMachine = stateMachine
        self.policyEngine = policyEngine
        self.shadowScheduler = shadowScheduler
        self.userDefaults = userDefaults
        self.handoffState = stateMachine.state
        self.settings = HandoffSettings.load(from: userDefaults)
        self.ownership = OmniBLEOwnership(
            role: .phone,
            pumpManager: pumpManager,
            appGroupDefaults: userDefaults,
            initialState: stateMachine.state
        )
        self.settingsSyncProvider = settingsSyncProvider
        self.phoneStableDebounceSeconds = phoneStableDebounceOverride
            ?? Self.defaultPhoneStableDebounceSeconds

        // B.5.2 Issue #3b: observe phone-side time-zone changes (iOS posts this
        // when the user crosses a zone boundary, when Settings → General → Date
        // & Time changes, or when the carrier reports a TZ change). Trigger a
        // fresh sync emission so the watch picks up the new TimeZone.current
        // identifier promptly instead of lagging until the next settings change.
        // Closure-based observer pattern avoids the `@objc` complication;
        // `[weak self]` defends against retain cycles even though the orchestrator
        // is app-lifetime-scoped (owned by LoopAppManager).
        self.systemTZObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifySettingsChanged()
        }
    }

    deinit {
        // B.5.2 Issue #3b: explicit removal of the closure observer (token-based;
        // `removeObserver(self)` would not match it because the observer object
        // is the returned token, not `self`).
        if let observer = systemTZObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        coordinator.onHandoffMessage = { [weak self] message in
            Task { @MainActor in self?.handleIncoming(message: message) }
        }
        shadowScheduler.setFire { [weak self] in
            guard let self else { return }
            let effects = self.stateMachine.handle(.shadowStateRefreshDue)
            self.execute(effects)
        }
        policyEngine.start()
        shadowScheduler.start()

        // B.4 Issue #2: seed initial owner state for the policy engine. The
        // iOS state machine starts in .phoneDriver, so the phone is the
        // initial owner.
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

        // B.3.a Phase 6 — trigger point 1: emit settings on WCSession connect.
        // The coordinator's `start()` has already been called by the time the
        // orchestrator starts, so we fire once immediately on a background tick
        // to avoid blocking init while also racing any pending WCSession
        // activation. Fire-and-forget; the watch will update its cache.
        Task { @MainActor [weak self] in self?.emitSettingsSync() }
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
            return
        case .modeSwitch(let ms):
            execute(stateMachine.handle(.incomingModeSwitch(ms)))
        case .pairingHandoff(let ph):
            execute(stateMachine.handle(.incomingPairingHandoff(ph)))
            if let decoded = try? JSONDecoder().decode(OmniBLEHandoffPayload.self,
                                                       from: ph.pairingPayload) {
                ownership.cachePayload(decoded)   // B.2.e (replaces lastReceivedPayload assignment)
            }
        case .settingsSync:
            // Settings sync is phone → watch only; phone ignores inbound.
            break
        case .algorithmStateSnapshot:
            // B.8 prep: snapshots are phone → watch only; phone ignores any
            // inbound. Substantive handling (defensive ignore log) lands in T7.
            break
        }
    }

    /// B.3.a Phase 6: emit settings sync via trigger point 2 (settings change).
    /// As of B.5.2 Phase 4, the sole production caller is the iOS
    /// `.NSSystemTimeZoneDidChange` observer in `init(...)` — there is no
    /// LoopSettings-change observer wired up yet. A future LoopSettings
    /// observer (e.g. on `LoopDataManager.didUpdate*`) should also route
    /// through here. Fire-and-forget; debounce is the caller's responsibility.
    func notifySettingsChanged() {
        emitSettingsSync()
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
            case .sendSettingsSync(let sync):
                // B.3.a Phase 6: deliver the concrete sync message the state
                // machine already built (it carries the snapshot value).
                coordinator.sendSettingsSync(sync)
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
                break
            case .notifyUI(let state):
                handoffState = state
                // B.3.a Phase 6 — trigger point 3: emit on handoff transition
                // entering .handoffPending (the watch will become the driver).
                if case .handoffPending(direction: .phoneToWatch, _, _) = state {
                    emitSettingsSync()
                }
                // B.4 Issue #2: mark current owner on every state transition
                // so the policy engine knows whose perspective to evaluate from.
                if let owner = state.currentOwner {
                    policyEngine.markCurrentOwner(owner)
                }
                ownership.update(state: state)   // B.2.e
            }
        }
    }

    /// B.3.a Phase 6: builds a `PhoneWatchSettingsSync` from the provider
    /// closure and queues it via the coordinator. No-op when the provider
    /// returns nil (settings not yet available) or when not wired.
    func emitSettingsSync() {
        guard let provider = settingsSyncProvider,
              let sync = provider() else { return }
        coordinator.sendSettingsSync(sync)
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
}
