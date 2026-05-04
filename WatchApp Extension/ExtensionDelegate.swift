//
//  ExtensionDelegate.swift
//  WatchApp Extension
//
//  Created by Nathan Racklyeft on 8/29/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import SwiftUI
import WatchConnectivity
import WatchKit
import HealthKit
import Intents
import os
import os.log
import UserNotifications
import Combine
import LoopKit
import LoopCore
import OmniBLE
import WatchAlgorithmKit  // for WatchAlgorithmStores (B.6 Phase 4a-bis)


final class ExtensionDelegate: NSObject, WKExtensionDelegate {
    private(set) lazy var loopManager = WatchContextManager()

    // B.2.c.1: hosted B.2.a-d stack
    private(set) var phoneWatchTransport: WCSessionPhoneWatchTransport?
    private(set) var phoneWatchCoordinator: PhoneWatchSessionCoordinator?
    private(set) var handoffOrchestrator: HandoffOrchestrator?
    private(set) var glucoseReader: GlucoseReader?
    private(set) var healthKitWriter: HealthKitWriter?
    private(set) var extendedRuntimeCoordinator: ExtendedRuntimeCoordinator?

    // B.3.a Phase 5: watch self-driving bootstraps
    private(set) var watchAlgorithmBootstrap: WatchAlgorithmBootstrap?
    private(set) var watchRemoteCommandBootstrap: WatchRemoteCommandBootstrap?
    private(set) var backgroundPollScheduler: BackgroundPollScheduler?

    // Phase 6 note: settings are now read directly from `WatchSettingsCache.shared`
    // via closure injection in bootstrapWatchSelfDrivingStack. The Phase 5
    // `watchSettingsSnapshot` field has been removed.

    /// Phase 5 supporting stores for `RemoteDataServicesManager`. Built lazily
    /// the first time the watch becomes the driver and retained for the
    /// lifetime of the process.
    private var lazyRemoteCommandStores: WatchRemoteCommandStores?

    /// Phase 5 dosing-decision store, built lazily for the algorithm runner.
    /// Watch doesn't currently persist dosing decisions to a real cache;
    /// uses an in-memory persistence controller.
    private var lazyDosingDecisionStore: DosingDecisionStore?

    /// Phase 5 dose store, built lazily.
    private var lazyDoseStore: DoseStore?

    private let log = OSLog(category: "ExtensionDelegate")

    private var observers: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var handoffStateCancellable: AnyCancellable?

    /// B.8.4: shared App Group file used as the file-pointer fallback for
    /// oversized algorithm-state snapshot payloads. Mirrors the path used
    /// by `WCSessionPhoneWatchTransport` on the phone side.
    private static let snapshotFileURL: URL =
        HandoffSettings.appGroupContainerURL.appendingPathComponent("snapshot.json")

    /// B.8.4: highest snapshot-pointer sequence the watch has seen this
    /// process lifetime. Pointer messages with sequence ≤ this are dropped
    /// as out-of-order (or replay). In-memory only — restart resets to 0,
    /// in which case the worst case is the watch reads the file once on
    /// the first post-relaunch pointer, which is benign.
    private var lastSeenSnapshotSequence: UInt64 = 0

    /// B.8.4: dedicated decoder for the pointer→inline rewrap path. Mirrors
    /// the date-encoding strategy used by `WCSessionPhoneWatchTransport`.
    private let snapshotDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// B.8.4: dedicated encoder for re-wrapping the file-loaded snapshot
    /// as an inline `PhoneWatchMessage.algorithmStateSnapshot(_)` so it
    /// can flow through the existing transport dispatch path.
    private let snapshotEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static func shared() -> ExtensionDelegate {
        return WKExtension.shared().extensionDelegate
    }

    override init() {
        super.init()

        let session = WCSession.default
        session.delegate = self

        // It seems, according to [this sample code](https://developer.apple.com/library/prerelease/content/samplecode/QuickSwitch/Listings/QuickSwitch_WatchKit_Extension_ExtensionDelegate_swift.html#//apple_ref/doc/uid/TP40016647-QuickSwitch_WatchKit_Extension_ExtensionDelegate_swift-DontLinkElementID_8)
        // that WCSession activation and delegation and WKWatchConnectivityRefreshBackgroundTask don't have any determinism,
        // and that KVO is the "recommended" way to deal with it.
        observers.append(session.observe(\WCSession.activationState) { [weak self] (session, change) in
            self?.log.default("WCSession.applicationState did change to %d", session.activationState.rawValue)

            DispatchQueue.main.async {
                self?.completePendingConnectivityTasksIfNeeded()
            }
        })
        observers.append(session.observe(\WCSession.hasContentPending) { [weak self] (session, change) in
            self?.log.default("WCSession.hasContentPending did change to %d", session.hasContentPending)

            DispatchQueue.main.async {
                self?.loopManager.sendDidUpdateContextNotificationIfNecessary()
                self?.completePendingConnectivityTasksIfNeeded()
            }
        })

        notifications.append(NotificationCenter.default.addObserver(forName: WatchContextManager.didUpdateContextNotification, object: loopManager, queue: nil) { [weak self] (_) in
            DispatchQueue.main.async {
                self?.loopManagerDidUpdateContext()
            }
        })

        session.activate()

        // B.2.c.1: bootstrap B.2.a-d stack alongside loopManager.
        bootstrapPhoneWatchStack()
    }

    deinit {
        for notification in notifications {
            NotificationCenter.default.removeObserver(notification)
        }
    }

    /// B.2.c.1: construct and start the B.2.a-d stack. Called from init() after
    /// session.activate(). Each component is independent; failure to construct
    /// any one shouldn't prevent the others from running.
    private func bootstrapPhoneWatchStack() {
        // WCSession transport + coordinator + heartbeat
        let transport = WCSessionPhoneWatchTransport()
        let coordinator = PhoneWatchSessionCoordinator(transport: transport)
        coordinator.start()
        self.phoneWatchTransport = transport
        self.phoneWatchCoordinator = coordinator

        // HealthKit writer + G7 reader (G7 reader needs phone-side state via SharedStateBridge)
        let writer = HealthKitWriter()
        Task { try? await writer.requestAuthorization() }
        self.healthKitWriter = writer

        let glucoseReader = GlucoseReader()
        if let bridge = SharedStateBridge.forAppGroup(HandoffSettings.appGroupIdentifier),
           let rawState = bridge.loadG7RawState() {
            glucoseReader.attach(rawState: rawState)
        } else {
            log.default("B.2.c.1: no G7 raw state in shared App Group — pair sensor in Loop iOS first")
        }
        self.glucoseReader = glucoseReader

        // extended runtime session for prolonged BLE
        let runtime = ExtendedRuntimeCoordinator()
        self.extendedRuntimeCoordinator = runtime

        // handoff orchestrator (subscribes to coordinator's onHandoffMessage)
        let appGroupDefaults = HandoffSettings.appGroupDefaults
        let settings = HandoffSettings.load(from: appGroupDefaults)
        let policyEngine = HandoffPolicyEngine(
            coordinator: coordinator,
            settings: settings,
            emit: { _ in }  // wired via orchestrator; placeholder avoids capture cycles at init
        )
        let scheduler = ShadowStateScheduler(fire: {})  // orchestrator re-wires via setFire in start()
        let stateMachine = HandoffStateMachine(initialState: .phoneDriver, role: .watch)
        let orchestrator = HandoffOrchestrator(
            coordinator: coordinator,
            stateMachine: stateMachine,
            policyEngine: policyEngine,
            shadowScheduler: scheduler,
            userDefaults: appGroupDefaults
        )
        orchestrator.start()
        self.handoffOrchestrator = orchestrator
        // publish singleton so PhoneWatchSessionCoordinator's
        // split-brain detection can read currentOwner + flip ownership.commandsAllowed.
        HandoffOrchestrator.shared = orchestrator

        // B.3.a Phase 5: watch self-driving bootstraps
        bootstrapWatchSelfDrivingStack(orchestrator: orchestrator)
    }

    /// B.3.a Phase 5: construct the algorithm + remote-command bootstraps and
    /// the background poll scheduler, then subscribe to the orchestrator's
    /// `handoffState` publisher so each transition fans out to both
    /// bootstraps.
    private func bootstrapWatchSelfDrivingStack(orchestrator: HandoffOrchestrator) {
        // B.3.a Phase 6: read settings from `WatchSettingsCache.shared` which is
        // populated by `PhoneWatchSessionCoordinator` when a `.settingsSync`
        // message arrives from the phone.
        let algorithmBootstrap = WatchAlgorithmBootstrap(
            storesProvider: { [weak self] in self?.makeAlgorithmStoresIfPossible() },
            syncProvider: { WatchSettingsCache.shared.current },
            // thread the lazily-constructed OmniBLEPumpManager through to the driver.
            // [weak] capture avoids a retain cycle through ExtensionDelegate -> bootstrap.
            pumpManagerProvider: { [weak orchestrator] in orchestrator?.pumpManager }
        )
        let remoteBootstrap = WatchRemoteCommandBootstrap(
            storesProvider: { [weak self] in self?.makeAlgorithmStoresIfPossible() },
            supportingStoresProvider: { [weak self] in self?.makeSupportingStoresIfPossible() },
            syncProvider: { WatchSettingsCache.shared.current }
        )
        let pollScheduler = BackgroundPollScheduler(
            shouldPoll: { [weak remoteBootstrap] in remoteBootstrap?.manager != nil },
            performPoll: { [weak remoteBootstrap] in remoteBootstrap?.triggerPollIfActive() }
        )

        self.watchAlgorithmBootstrap = algorithmBootstrap
        self.watchRemoteCommandBootstrap = remoteBootstrap
        self.backgroundPollScheduler = pollScheduler

        // Fan handoff-state changes out to both bootstraps. Re-publishes are
        // idempotent so we don't need to dedup on `removeDuplicates`.
        handoffStateCancellable = orchestrator.$handoffState
            .receive(on: DispatchQueue.main)
            .sink { state in
                algorithmBootstrap.update(handoffState: state)
                remoteBootstrap.update(handoffState: state)
            }

        // Note: the first background-refresh schedule call must happen after
        // applicationDidFinishLaunching, otherwise WKExtension throws
        // "WKExtensionDelegate (null)". See `applicationDidFinishLaunching`.
    }

    /// Phase 5 watch-side stores assembly. CarbStore + GlucoseStore are
    /// reused from `WatchContextManager`; DoseStore + DosingDecisionStore
    /// are built lazily on first access.
    private func makeAlgorithmStoresIfPossible() -> WatchAlgorithmStores? {
        let cacheStore = PersistenceController.controllerInLocalDirectory()
        if lazyDoseStore == nil {
            lazyDoseStore = DoseStore(
                cacheStore: cacheStore,
                cacheLength: .hours(24),
                insulinModelProvider: PresetInsulinModelProvider(defaultRapidActingModel: nil),
                longestEffectDuration: ExponentialInsulinModelPreset.rapidActingAdult.effectDuration,
                basalProfile: nil,
                insulinSensitivitySchedule: nil,
                overrideHistory: nil,
                lastPumpEventsReconciliation: nil,
                provenanceIdentifier: HKSource.default().bundleIdentifier
            )
        }
        if lazyDosingDecisionStore == nil {
            lazyDosingDecisionStore = DosingDecisionStore(
                store: cacheStore,
                expireAfter: .hours(24)
            )
        }
        guard let doseStore = lazyDoseStore,
              let ddStore = lazyDosingDecisionStore else {
            return nil
        }
        return WatchAlgorithmStores(
            carbStore: loopManager.carbStore,
            doseStore: doseStore,
            glucoseStore: loopManager.glucoseStore,
            dosingDecisionStore: ddStore
        )
    }

    /// Phase 5 supporting stores for `RemoteDataServicesManager`.
    private func makeSupportingStoresIfPossible() -> WatchRemoteCommandStores? {
        if lazyRemoteCommandStores == nil {
            let cacheStore = PersistenceController.controllerInLocalDirectory()
            lazyRemoteCommandStores = WatchRemoteCommandStores(
                cgmEventStore: CgmEventStore(cacheStore: cacheStore, cacheLength: .hours(24)),
                settingsStore: SettingsStore(store: cacheStore, expireAfter: .hours(24)),
                overrideHistory: TemporaryScheduleOverrideHistory(),
                insulinDeliveryStore: InsulinDeliveryStore(
                    cacheStore: cacheStore,
                    cacheLength: .hours(24),
                    provenanceIdentifier: HKSource.default().bundleIdentifier
                )
            )
        }
        return lazyRemoteCommandStores
    }

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        if #available(watchOSApplicationExtension 5.0, *) {
            INRelevantShortcutStore.default.registerShortcuts()
        }
        // check for interrupted dose recovery tripwire on app launch.
        // If a stale entry (>60s old) is found, it gets logged at .error
        // and cleared. Pod history is the source of truth.
        let recoveryDefaults = HandoffSettings.appGroupDefaults
        WatchDoseRecoveryStore.checkAndClearStale(in: recoveryDefaults)
        // B.3.a Phase 5: schedule the first background poll wake. Must happen
        // after WKExtension has the delegate wired up, otherwise the call
        // crashes with "WKExtensionDelegate (null)".
        backgroundPollScheduler?.scheduleNext()
    }

    func applicationDidBecomeActive() {
        if WCSession.default.activationState != .activated {
            WCSession.default.activate()
        }

        extendedRuntimeCoordinator?.onScenePhaseChange(.active)
        NotificationCenter.default.post(name: type(of: self).didBecomeActiveNotification, object: self)
    }

    func applicationWillResignActive() {
        UserDefaults.standard.startOnChartPage = (WKExtension.shared().visibleInterfaceController as? ChartHUDController) != nil

        extendedRuntimeCoordinator?.onScenePhaseChange(.background)
        NotificationCenter.default.post(name: type(of: self).willResignActiveNotification, object: self)
    }

    // Presumably the main thread?
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        loopManager.requestGlucoseBackfillIfNecessary()

        for task in backgroundTasks {
            switch task {
            case is WKApplicationRefreshBackgroundTask:
                log.default("Processing WKApplicationRefreshBackgroundTask")
                // B.3.a Phase 5: trigger remote-data poll cycle if the
                // watch is currently the driver and Nightscout is configured.
                backgroundPollScheduler?.handleWake()
                break
            case let task as WKSnapshotRefreshBackgroundTask:
                log.default("Processing WKSnapshotRefreshBackgroundTask")
                task.setTaskCompleted(restoredDefaultState: false, estimatedSnapshotExpiration: Date(timeIntervalSinceNow: TimeInterval(minutes: 5)), userInfo: nil)
                return  // Don't call the standard setTaskCompleted handler
            case is WKURLSessionRefreshBackgroundTask:
                break
            case let task as WKWatchConnectivityRefreshBackgroundTask:
                log.default("Processing WKWatchConnectivityRefreshBackgroundTask")

                pendingConnectivityTasks.append(task)

                if WCSession.default.activationState != .activated {
                    WCSession.default.activate()
                }

                completePendingConnectivityTasksIfNeeded()
                return // Defer calls to the setTaskCompleted handler
            default:
                break
            }

            if #available(watchOSApplicationExtension 4.0, *) {
                task.setTaskCompletedWithSnapshot(false)
            } else {
                task.setTaskCompleted()
            }
        }
    }

    private var pendingConnectivityTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    private func completePendingConnectivityTasksIfNeeded() {
        if WCSession.default.activationState == .activated && !WCSession.default.hasContentPending {
            pendingConnectivityTasks.forEach { (task) in
                self.log.default("Completing WKWatchConnectivityRefreshBackgroundTask %{public}@", String(describing: task))
                if #available(watchOSApplicationExtension 4.0, *) {
                    task.setTaskCompletedWithSnapshot(false)
                } else {
                    task.setTaskCompleted()
                }
            }
            pendingConnectivityTasks.removeAll()
        }
    }

    func handle(_ userActivity: NSUserActivity) {
        if #available(watchOSApplicationExtension 5.0, *) {
            switch userActivity.activityType {
            case NSUserActivity.newCarbEntryActivityType, NSUserActivity.didAddCarbEntryOnWatchActivityType:
                if let statusController = WKExtension.shared().visibleInterfaceController as? HUDInterfaceController {
                    statusController.addCarbs()
                }
            default:
                break
            }
        }
    }

    private func updateContext(_ data: [String: Any]) {
        guard let context = WatchContext(rawValue: data) else {
            log.error("Could not decode WatchContext: %{public}@", data)
            return
        }

        if context.displayGlucoseUnit == nil {
            let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
            loopManager.healthStore.preferredUnits(for: [type]) { (units, error) in
                context.displayGlucoseUnit = units[type]

                DispatchQueue.main.async {
                    self.loopManager.updateContext(context)
                }
            }
        } else {
            DispatchQueue.main.async {
                self.loopManager.updateContext(context)
            }
        }
    }

    private func loopManagerDidUpdateContext() {
        dispatchPrecondition(condition: .onQueue(.main))

        if WKExtension.shared().applicationState != .active {
            WKExtension.shared().scheduleSnapshotRefresh(withPreferredDate: Date(), userInfo: nil) { (error) in
                if let error = error {
                    self.log.error("scheduleSnapshotRefresh error: %{public}@", String(describing: error))
                }
            }
        }

        // Update complication data if needed
        let server = CLKComplicationServer.sharedInstance()
        for complication in server.activeComplications ?? [] {
            log.default("Reloading complication timeline")
            server.reloadTimeline(for: complication)
        }
    }
}


extension ExtensionDelegate: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            // at activation the OS hands us the last-received
            // applicationContext, which under the new routing is the most-recent
            // AlgorithmStateSnapshot. Mirror the didReceiveApplicationContext
            // dispatch so the snapshot reaches the transport at takeover.
            let context = session.receivedApplicationContext
            if let data = context["phoneWatchMessage"] as? Data {
                handlePhoneWatchMessageData(data)
            } else {
                updateContext(context)
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        log.default("didReceiveApplicationContext")
        // forward applicationContext-delivered phoneWatchMessage
        // to the transport. The phone now uses updateApplicationContext
        // (latest-only) for AlgorithmStateSnapshot delivery instead of
        // transferUserInfo, so we reuse the same Data convention the
        // didReceiveUserInfo path uses.
        if let data = applicationContext["phoneWatchMessage"] as? Data {
            handlePhoneWatchMessageData(data)
            return
        }
        // Legacy WatchContext fallback (preserved unchanged).
        updateContext(applicationContext)
    }

    /// B.8.4: dispatch helper for applicationContext-delivered
    /// `phoneWatchMessage` Data. Recognizes the file-pointer fallback case
    /// (`algorithmStateSnapshotPointer`), validates monotonic sequence,
    /// reads the snapshot from the App Group file, re-wraps as inline
    /// `algorithmStateSnapshot`, and forwards through the transport so
    /// the existing B.8 cache + B.8.4 driver hydration path runs as if
    /// the payload had arrived inline. Inline messages (small snapshots,
    /// or any non-snapshot envelope) bypass this special-casing.
    private func handlePhoneWatchMessageData(_ data: Data) {
        // Try to decode the envelope first — only the pointer case needs
        // the file-read shim. Decode failures fall through to the transport
        // which handles its own errors.
        if let message = try? snapshotDecoder.decode(PhoneWatchMessage.self, from: data),
           case .algorithmStateSnapshotPointer(let sequence) = message {
            handleSnapshotPointer(sequence: sequence)
            return
        }
        // Inline path (B.8.2): hand straight to the transport.
        phoneWatchTransport?.handleIncomingMessageData(data, replyHandler: nil)
    }

    /// B.8.4: pointer-message handler. Drops out-of-order/replayed pointers
    /// (sequence ≤ lastSeen), reads `<AppGroup>/snapshot.json`, re-wraps the
    /// payload as an inline `.algorithmStateSnapshot`, and forwards through
    /// the existing transport dispatch.
    private func handleSnapshotPointer(sequence: UInt64) {
        guard sequence > lastSeenSnapshotSequence else {
            log.default("snapshot pointer seq=%llu ≤ lastSeen=%llu — ignoring out-of-order/replay",
                        sequence, lastSeenSnapshotSequence)
            return
        }
        do {
            let payloadData = try Data(contentsOf: Self.snapshotFileURL)
            let snapshot = try snapshotDecoder.decode(AlgorithmStateSnapshot.self, from: payloadData)
            // Update lastSeen only after the read succeeds. If the file
            // was missing/corrupt we leave lastSeen alone so that a retry
            // with the same sequence (e.g., the OS re-delivers at activation)
            // can succeed once the file lands.
            lastSeenSnapshotSequence = sequence
            let inlineMessage = PhoneWatchMessage.algorithmStateSnapshot(snapshot)
            let inlineData = try snapshotEncoder.encode(inlineMessage)
            phoneWatchTransport?.handleIncomingMessageData(inlineData, replyHandler: nil)
            log.default("snapshot pointer seq=%llu read %d bytes from snapshot.json", sequence, payloadData.count)
        } catch {
            log.error("snapshot pointer seq=%llu read/decode failed: %{public}@",
                      sequence, String(describing: error))
        }
    }

    // This method is called on a background thread of your app
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        // B.2.c.1: forward new B.2.c-d phoneWatchMessage userInfo to the transport
        if let data = userInfo["phoneWatchMessage"] as? Data {
            phoneWatchTransport?.handleIncomingMessageData(data, replyHandler: nil)
            return
        }

        let name = userInfo["name"] as? String ?? "WatchContext"

        log.default("didReceiveUserInfo: %{public}@", name)

        switch name {
        case LoopSettingsUserInfo.name:
            if let settings = LoopSettingsUserInfo(rawValue: userInfo)?.settings {
                DispatchQueue.main.async {
                    self.loopManager.settings = settings
                }
            } else {
                log.error("Could not decode LoopSettingsUserInfo: %{public}@", userInfo)
            }
        case SupportedBolusVolumesUserInfo.name:
            guard let volumes = SupportedBolusVolumesUserInfo(rawValue: userInfo)?.supportedBolusVolumes else {
                log.error("Could not decode SupportedBolusVolumesUserInfo: %{public}@", userInfo)
                return
            }

            DispatchQueue.main.async {
                self.loopManager.supportedBolusVolumes = volumes
            }
        case "WatchContext":
            // WatchContext is the only userInfo type without a "name" key. This isn't a great heuristic.
            updateContext(userInfo)
        default:
            break
        }
    }

    /// B.2.c.1: legacy ExtensionDelegate didn't implement this; B.2.c uses
    /// sendMessageData for heartbeats. Forward to the new transport.
    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        guard let transport = phoneWatchTransport else {
            replyHandler(Data())
            return
        }
        transport.handleIncomingMessageData(messageData, replyHandler: replyHandler)
    }
}


extension ExtensionDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            guard
                response.notification.request.identifier == LoopNotificationCategory.missedMeal.rawValue,
                let statusController = WKExtension.shared().visibleInterfaceController as? HUDInterfaceController
            else {
                break
            }

            let userInfo = response.notification.request.content.userInfo
            // If we have info about a meal, the carb entry UI should reflect it
            if
                let mealTime = userInfo[LoopNotificationUserInfoKey.missedMealTime.rawValue] as? Date,
                let carbAmount = userInfo[LoopNotificationUserInfoKey.missedMealCarbAmount.rawValue] as? Double
            {
                let missedEntry = NewCarbEntry(quantity: HKQuantity(unit: .gram(),
                                                                         doubleValue: carbAmount),
                                                    startDate: mealTime,
                                                    foodType: nil,
                                                    absorptionTime: nil)
                statusController.addCarbs(initialEntry: missedEntry)
            // Otherwise, just provide the ability to add carbs
            } else {
                statusController.addCarbs()
            }
        default:
            break
        }

        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.badge, .sound, .list, .banner])
    }
}


extension ExtensionDelegate {
    static let didBecomeActiveNotification = Notification.Name("com.loopkit.Loop.LoopWatch.didBecomeActive")

    static let willResignActiveNotification = Notification.Name("com.loopkit.Loop.LoopWatch.willResignActive")

    /// Global shortcut to present an alert for a specific error out-of-context with a specific interface controller.
    ///
    /// - parameter error: The error whose contents to display
    func present(_ error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))

        WKExtension.shared().rootInterfaceController?.presentAlert(withTitle: error.localizedDescription, message: (error as NSError).localizedRecoverySuggestion ?? (error as NSError).localizedFailureReason, preferredStyle: .alert, actions: [WKAlertAction.dismissAction()])
    }
}


fileprivate extension WKExtension {
    var extensionDelegate: ExtensionDelegate! {
        return delegate as? ExtensionDelegate
    }
}
