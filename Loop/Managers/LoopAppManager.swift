//
//  LoopAppManager.swift
//  Loop
//
//  Created by Darin Krauss on 2/16/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import UIKit
import Intents
import Combine
import LoopKit
import LoopKitUI
import MockKit
import HealthKit
import WidgetKit
import OmniBLE

#if targetEnvironment(simulator)
enum SimulatorError: Error {
    case remoteNotificationsNotAvailable
}
#endif

public protocol AlertPresenter: AnyObject {
    /// Present the alert view controller, with or without animation.
    /// - Parameters:
    ///   - viewControllerToPresent: The alert view controller to present.
    ///   - animated: Animate the alert view controller presentation or not.
    ///   - completion: Completion to call once view controller is presented.
    func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)?)

    /// Retract any alerts with the given identifier.  This includes both pending and delivered alerts.

    /// Dismiss the topmost view controller, presumably the alert view controller.
    /// - Parameters:
    ///   - animated: Animate the alert view controller dismissal or not.
    ///   - completion: Completion to call once view controller is dismissed.
    func dismissTopMost(animated: Bool, completion: (() -> Void)?)

    /// Dismiss an alert, even if it is not the top most alert.
    /// - Parameters:
    ///   - alertToDismiss: The alert to dismiss
    ///   - animated: Animate the alert view controller dismissal or not.
    ///   - completion: Completion to call once view controller is dismissed.
    func dismissAlert(_ alertToDismiss: UIAlertController, animated: Bool, completion: (() -> Void)?)
}

public extension AlertPresenter {
    func present(_ viewController: UIViewController, animated: Bool) { present(viewController, animated: animated, completion: nil) }
    func dismissTopMost(animated: Bool) { dismissTopMost(animated: animated, completion: nil) }
    func dismissAlert(_ alertToDismiss: UIAlertController, animated: Bool) { dismissAlert(alertToDismiss, animated: animated, completion: nil) }
}

protocol WindowProvider: AnyObject {
    var window: UIWindow? { get }
}

class LoopAppManager: NSObject {
    private enum State: Int {
        case initialize
        case checkProtectedDataAvailable
        case launchManagers
        case launchOnboarding
        case launchHomeScreen
        case launchComplete

        var next: State { State(rawValue: rawValue + 1) ?? .launchComplete }
    }

    private weak var windowProvider: WindowProvider?
    private var launchOptions: [UIApplication.LaunchOptionsKey: Any]?

    private var pluginManager: PluginManager!
    private var bluetoothStateManager: BluetoothStateManager!
    private var alertManager: AlertManager!
    private var trustedTimeChecker: TrustedTimeChecker!
    private var deviceDataManager: DeviceDataManager!
    private var onboardingManager: OnboardingManager!
    private var alertPermissionsChecker: AlertPermissionsChecker!
    private var supportManager: SupportManager!
    private var settingsManager: SettingsManager!
    private var loggingServicesManager = LoggingServicesManager()
    private var analyticsServicesManager = AnalyticsServicesManager()
    private(set) var testingScenariosManager: TestingScenariosManager?
    private var resetLoopManager: ResetLoopManager!
    private var deeplinkManager: DeeplinkManager!

    // B.2.c: phone↔watch WCSession coordinator. Activated during launchManagers().
    // Public so SwiftUI views (e.g., WatchConnectionStatusRow) can observe it.
    // B.2.c.1: no longer lazy — constructed explicitly in launchManagers() so
    // the transport instance can be shared with WatchDataManager.
    @MainActor private(set) var phoneWatchCoordinator: PhoneWatchSessionCoordinator!

    // B.2.d: bonding-handoff orchestrator. Started during launchManagers() after
    // the coordinator. Public so SwiftUI views (Settings → Watch Handoff) can
    // observe it.
    @MainActor private(set) var phoneWatchHandoffOrchestrator: HandoffOrchestrator?

    // B.8: emitter that pushes AlgorithmStateSnapshot to the watch after every
    // successful Loop iteration. LoopAppManager owns the strong reference;
    // LoopDataManager holds a weak back-pointer (`weak var
    // algorithmStateSnapshotEmitter`).
    @MainActor private var algorithmStateSnapshotEmitter: AlgorithmStateSnapshotEmitter?

    private var overrideHistory = UserDefaults.appGroup?.overrideHistory ?? TemporaryScheduleOverrideHistory.init()

    private var state: State = .initialize

    private let log = DiagnosticLog(category: "LoopAppManager")
    private let widgetLog = DiagnosticLog(category: "LoopWidgets")

    private let automaticDosingStatus = AutomaticDosingStatus(automaticDosingEnabled: false, isAutomaticDosingAllowed: false)

    lazy private var cancellables = Set<AnyCancellable>()

    func initialize(windowProvider: WindowProvider, launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .initialize)

        self.windowProvider = windowProvider
        self.launchOptions = launchOptions
        
        if FeatureFlags.siriEnabled && INPreferences.siriAuthorizationStatus() == .notDetermined {
            INPreferences.requestSiriAuthorization { _ in }
        }

        registerBackgroundTasks()

        if FeatureFlags.remoteCommandsEnabled {
            DispatchQueue.main.async {
#if targetEnvironment(simulator)
                self.remoteNotificationRegistrationDidFinish(.failure(SimulatorError.remoteNotificationsNotAvailable))
#else
                UIApplication.shared.registerForRemoteNotifications()
#endif
            }
        }
        self.state = state.next
    }

    func launch() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(isLaunchPending)

        resumeLaunch()
    }

    var isLaunchPending: Bool { state == .checkProtectedDataAvailable }

    var isLaunchComplete: Bool { state == .launchComplete }

    private func resumeLaunch() {
        if state == .checkProtectedDataAvailable {
            checkProtectedDataAvailable()
        }
        if state == .launchManagers {
            launchManagers()
        }
        if state == .launchOnboarding {
            launchOnboarding()
        }
        if state == .launchHomeScreen {
            launchHomeScreen()
        }
        
        askUserToConfirmLoopReset()
    }

    private func checkProtectedDataAvailable() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .checkProtectedDataAvailable)

        guard isProtectedDataAvailable() else {
            log.default("Protected data not available; deferring launch...")
            return
        }

        self.state = state.next
    }

    private func launchManagers() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .launchManagers)

        windowProvider?.window?.tintColor = .loopAccent
        OrientationLock.deviceOrientationController = self
        UNUserNotificationCenter.current().delegate = self

        resetLoopManager = ResetLoopManager(delegate: self)

        let localCacheDuration = Bundle.main.localCacheDuration
        let cacheStore = PersistenceController.controllerInAppGroupDirectory()

        pluginManager = PluginManager()


        bluetoothStateManager = BluetoothStateManager()
        alertManager = AlertManager(alertPresenter: self,
                                    userNotificationAlertScheduler: UserNotificationAlertScheduler(userNotificationCenter: UNUserNotificationCenter.current()),
                                    expireAfter: Bundle.main.localCacheDuration,
                                    bluetoothProvider: bluetoothStateManager,
                                    analyticsServicesManager: analyticsServicesManager)

        alertPermissionsChecker = AlertPermissionsChecker()
        alertPermissionsChecker.delegate = alertManager
        
        trustedTimeChecker = TrustedTimeChecker(alertManager: alertManager)

        settingsManager = SettingsManager(cacheStore: cacheStore,
                                               expireAfter: localCacheDuration,
                                               alertMuter: alertManager.alertMuter)

        deviceDataManager = DeviceDataManager(pluginManager: pluginManager,
                                              alertManager: alertManager,
                                              settingsManager: settingsManager,
                                              loggingServicesManager: loggingServicesManager,
                                              analyticsServicesManager: analyticsServicesManager,
                                              bluetoothProvider: bluetoothStateManager,
                                              alertPresenter: self,
                                              automaticDosingStatus: automaticDosingStatus,
                                              cacheStore: cacheStore,
                                              localCacheDuration: localCacheDuration,
                                              overrideHistory: overrideHistory,
                                              trustedTimeChecker: trustedTimeChecker
        )
        settingsManager.deviceStatusProvider = deviceDataManager
        settingsManager.displayGlucosePreference = deviceDataManager.displayGlucosePreference


        overrideHistory.delegate = self

        SharedLogging.instance = loggingServicesManager

        scheduleBackgroundTasks()

        supportManager = SupportManager(pluginManager: pluginManager,
                                        deviceSupportDelegate: deviceDataManager,
                                        servicesManager: deviceDataManager.servicesManager,
                                        alertIssuer: alertManager)
        
        setWhitelistedDevices()

        onboardingManager = OnboardingManager(pluginManager: pluginManager,
                                              bluetoothProvider: bluetoothStateManager,
                                              deviceDataManager: deviceDataManager,
                                              statefulPluginManager: deviceDataManager.statefulPluginManager,
                                              servicesManager: deviceDataManager.servicesManager,
                                              loopDataManager: deviceDataManager.loopManager,
                                              supportManager: supportManager,
                                              windowProvider: windowProvider,
                                              userDefaults: UserDefaults.appGroup!)

        deeplinkManager = DeeplinkManager(rootViewController: rootViewController)

        for support in supportManager.availableSupports {
            if let analyticsService = support as? AnalyticsService {
                analyticsServicesManager.addService(analyticsService)
            }
            support.initializationComplete(for: deviceDataManager.allActivePlugins)
        }

        deviceDataManager.onboardingManager = onboardingManager

        // Analytics: user properties
        analyticsServicesManager.identifyAppName(Bundle.main.bundleDisplayName)

        if let workspaceGitRevision = BuildDetails.default.workspaceGitRevision {
            analyticsServicesManager.identifyWorkspaceGitRevision(workspaceGitRevision)
        }

        analyticsServicesManager.identify("Dosing Strategy", value: settingsManager.loopSettings.automaticDosingStrategy.analyticsValue)
        let serviceNames = deviceDataManager.servicesManager.activeServices.map { $0.pluginIdentifier }
        analyticsServicesManager.identify("Services", array: serviceNames)

        if FeatureFlags.scenariosEnabled {
            testingScenariosManager = LocalTestingScenariosManager(deviceManager: deviceDataManager, supportManager: supportManager)
        }

        analyticsServicesManager.application(didFinishLaunchingWithOptions: launchOptions)


        automaticDosingStatus.$isAutomaticDosingAllowed
            .combineLatest(deviceDataManager.loopManager.$dosingEnabled)
            .map { $0 && $1 }
            .assign(to: \.automaticDosingStatus.automaticDosingEnabled, on: self)
            .store(in: &cancellables)

        // B.2.c: start the phone↔watch coordinator. WCSession activation begins
        // immediately; heartbeats begin firing every 30s. Log-only stub handlers
        // for now (B.2.d/e supply real behavior).
        // B.2.c.1: construct shared transport, hand to both WatchDataManager
        // (which holds the WCSession delegate role) and the coordinator.
        Task { @MainActor in
            let phoneWatchTransport = WCSessionPhoneWatchTransport()
            self.deviceDataManager.watchManager.phoneWatchTransport = phoneWatchTransport

            let phoneWatchCoordinator = PhoneWatchSessionCoordinator(transport: phoneWatchTransport)
            PhoneWatchSessionCoordinator.shared = phoneWatchCoordinator
            self.phoneWatchCoordinator = phoneWatchCoordinator
            phoneWatchCoordinator.start()

            // B.2.d: instantiate and start handoff orchestrator + policy + scheduler.
            let appGroupDefaults = HandoffSettings.appGroupDefaults
            let handoffSettings = HandoffSettings.load(from: appGroupDefaults)
            let stateMachine = HandoffStateMachine(initialState: .phoneDriver, role: .phone)
            let policyEngine = HandoffPolicyEngine(
                coordinator: self.phoneWatchCoordinator,
                settings: handoffSettings,
                emit: { _ in /* wired via orchestrator */ }
            )
            let scheduler = ShadowStateScheduler(role: .phone, fire: { /* wired via orchestrator */ })
            let orchestrator = HandoffOrchestrator(
                coordinator: self.phoneWatchCoordinator,
                stateMachine: stateMachine,
                policyEngine: policyEngine,
                shadowScheduler: scheduler,
                userDefaults: appGroupDefaults,
                pumpManager: deviceDataManager.pumpManager as? OmniBLEPumpManager,   // B.2.e
                settingsSyncProvider: { [weak self] in self?.currentSettingsSyncOrNil() }   // B.4 Issue #3
            )
            HandoffOrchestrator.shared = orchestrator
            orchestrator.start()
            self.phoneWatchHandoffOrchestrator = orchestrator

            // B.8.2 Issue #1: reverse-wire the orchestrator into LoopDataManager so
            // every settings mutation fans out to the watch handoff pipeline (mirrors
            // the algorithmStateSnapshotEmitter wire-up below).
            self.deviceDataManager?.loopManager?.watchHandoffOrchestrator = orchestrator

            // B.8: wire the algorithm-state snapshot emitter into LoopDataManager.
            // Use the concrete WCSessionPhoneWatchTransport already constructed
            // for the coordinator — SnapshotTransport conformance lives on the
            // concrete class, not on the PhoneWatchTransport protocol.
            let snapshotEmitter = AlgorithmStateSnapshotEmitter(
                transport: phoneWatchTransport,
                stateProvider: { [weak self] in
                    self?.currentSnapshotStateOrNil()
                }
            )
            self.algorithmStateSnapshotEmitter = snapshotEmitter
            self.deviceDataManager?.loopManager?.algorithmStateSnapshotEmitter = snapshotEmitter
        }

        state = state.next
    }

    /// B.4 Issue #3: Builds a `PhoneWatchSettingsSync` from current
    /// `LoopDataManager` settings. Returns nil if settings aren't yet
    /// available (e.g. very early launch). Used by `HandoffOrchestrator`'s
    /// `settingsSyncProvider` closure so `emitSettingsSync()` actually
    /// produces a payload in production (without this, the orchestrator
    /// returns at the `guard let provider` check and the entire Phase 6
    /// sync emission is dead code).
    @MainActor
    private func currentSettingsSyncOrNil() -> PhoneWatchSettingsSync? {
        guard let lm = self.deviceDataManager?.loopManager else { return nil }
        let settings = lm.settings
        guard let basal = settings.basalRateSchedule,
              let isf = settings.insulinSensitivitySchedule,
              let cr = settings.carbRatioSchedule,
              let targets = settings.glucoseTargetRangeSchedule,
              let maxBolus = settings.maximumBolus,
              let maxBasal = settings.maximumBasalRatePerHour
        else { return nil }

        // ISF wire format: mg/dL per unit. Convert from the schedule's native
        // unit via HKQuantity to handle mmol/L users correctly.
        let isfItems: [RepeatingScheduleValue<Double>] = isf.items.map {
            let mgdL = HKQuantity(unit: isf.unit, doubleValue: $0.value)
                .doubleValue(for: .milligramsPerDeciliter)
            return RepeatingScheduleValue(startTime: $0.startTime, value: mgdL)
        }

        // Glucose target wire format: mg/dL DoubleRange. Use the schedule's
        // own conversion API which preserves both bounds correctly.
        let targetsInMgdl = targets.schedule(for: .milligramsPerDeciliter) ?? targets
        let targetItems: [RepeatingScheduleValue<DoubleRange>] = targetsInMgdl.items

        // Suspend threshold wire format: mg/dL Double. Convert via HKQuantity.
        let suspendThresholdMgdL: Double? = settings.suspendThreshold.map {
            $0.quantity.doubleValue(for: .milligramsPerDeciliter)
        }

        // TODO(B.5 or later): wire from RemoteDataServicesManager.
        // Until then, watch loses Nightscout integration when running as
        // algorithm driver — but the watch's WatchSettingsSnapshot init handles
        // nil gracefully (skips Nightscout polling, no crash).
        let nsConfig: PhoneWatchSettingsSync.NightscoutConfig? = nil

        return PhoneWatchSettingsSync(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: Date(),
            basalScheduleItems: basal.items,
            insulinSensitivityScheduleItems: isfItems,
            carbRatioScheduleItems: cr.items,
            glucoseTargetRangeScheduleItems: targetItems,
            maximumBolusUnits: maxBolus,
            maximumBasalRatePerHourUnits: maxBasal,
            suspendThresholdMgdL: suspendThresholdMgdL,
            nightscoutConfig: nsConfig,
            automaticDosingEnabled: self.automaticDosingStatus.automaticDosingEnabled,
            isAutomaticDosingAllowed: self.automaticDosingStatus.isAutomaticDosingAllowed,
            // B.5.2 Issue #3: include the phone's current TimeZone identifier so
            // the watch can align its schedule lookups to the phone's local time
            // (e.g. "Europe/Copenhagen") even when the two devices report
            // different TimeZone.current. Read at emission time so each fresh
            // sync reflects the phone's current zone.
            timeZone: TimeZone.current.identifier
        )
    }

    /// B.8: build an `AlgorithmStateSnapshotEmitter.State` from current
    /// `LoopDataManager` + `DeviceDataManager` state. Returns nil when state
    /// isn't yet available (very early launch, before pump pairing, etc.).
    ///
    /// B.8.4 Phase 2: rolling buffers (`glucoseSamples` / `doseHistory` /
    /// `carbEntries`) are now read from `lm.lastAlgorithmInput`, which
    /// `LoopDataManager` refreshes at the end of each iteration via the same
    /// 10h-glucose / 16h-doses / runner-cached-carbs windows the algorithm
    /// itself consumes. Before the first iteration completes, the cache is
    /// nil and the buffers fall back to empty — emit() still produces a
    /// well-formed snapshot, the watch just can't skip warmup yet.
    ///
    /// `pumpStatus` is similarly minimal: capacity stands in for "remaining"
    /// (the live remaining is async-only) and `lastReadingDate` is `now`.
    /// The snapshot is a hint at takeover; the live pod is authoritative
    /// once bonded, so a sketchy `pumpStatus` is acceptable in Phase 1.
    @MainActor
    private func currentSnapshotStateOrNil() -> AlgorithmStateSnapshotEmitter.State? {
        guard let lm = self.deviceDataManager?.loopManager,
              let pumpManager = self.deviceDataManager?.pumpManager
        else { return nil }
        let pumpStatus = PumpStatusSnapshot(
            reservoirUnitsRemaining: pumpManager.pumpReservoirCapacity,
            lastBasalRateUnitsPerHour: nil,
            isSuspended: pumpManager.status.basalDeliveryState?.isSuspended ?? false,
            lastReadingDate: Date()
        )
        let cachedInput = lm.lastAlgorithmInput
        return AlgorithmStateSnapshotEmitter.State(
            iterationDate: lm.lastLoopCompleted ?? Date(),
            glucoseSamples: cachedInput?.glucoseHistory ?? [],
            doseHistory: cachedInput?.doses ?? [],
            carbEntries: cachedInput?.carbEntries ?? [],
            pumpStatus: pumpStatus,
            activeOverride: lm.settings.scheduleOverride
        )
    }

    private func launchOnboarding() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .launchOnboarding)

        onboardingManager.launch {
            DispatchQueue.main.async {
                self.state = self.state.next
                self.resumeLaunch()
            }
        }
    }

    private func launchHomeScreen() {
        dispatchPrecondition(condition: .onQueue(.main))
        precondition(state == .launchHomeScreen)

        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: Self.self))
        let statusTableViewController = storyboard.instantiateViewController(withIdentifier: "MainStatusViewController") as! StatusTableViewController
        statusTableViewController.alertPermissionsChecker = alertPermissionsChecker
        statusTableViewController.alertMuter = alertManager.alertMuter
        statusTableViewController.automaticDosingStatus = automaticDosingStatus
        statusTableViewController.deviceManager = deviceDataManager
        statusTableViewController.onboardingManager = onboardingManager
        statusTableViewController.supportManager = supportManager
        statusTableViewController.testingScenariosManager = testingScenariosManager
        bluetoothStateManager.addBluetoothObserver(statusTableViewController)

        var rootNavigationController = rootViewController as? RootNavigationController
        if rootNavigationController == nil {
            rootNavigationController = RootNavigationController()
            rootViewController = rootNavigationController
        }

        rootNavigationController?.setViewControllers([statusTableViewController], animated: true)

        deviceDataManager.refreshDeviceData()

        handleRemoteNotificationFromLaunchOptions()

        self.launchOptions = nil

        self.state = state.next

        alertManager.playbackAlertsFromPersistence()
    }

    // MARK: - Life Cycle

    func didBecomeActive() {
        if let rootViewController = rootViewController {
            AppExpirationAlerter.alertIfNeeded(viewControllerToPresentFrom: rootViewController)
        }
        settingsManager?.didBecomeActive()
        deviceDataManager?.didBecomeActive()
        alertManager.inferDeliveredLoopNotRunningNotifications()
        
        widgetLog.default("Refreshing widget. Reason: App didBecomeActive")
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Remote Notification
    
    func remoteNotificationRegistrationDidFinish(_ result: Result<Data,Error>) {
        if case .success(let token) = result {
            log.default("DeviceToken: %{public}@", token.hexadecimalString)
        }
        settingsManager.remoteNotificationRegistrationDidFinish(result)
    }

    private func handleRemoteNotificationFromLaunchOptions() {
        handleRemoteNotification(launchOptions?[.remoteNotification] as? [String: AnyObject])
    }

    @discardableResult
    func handleRemoteNotification(_ notification: [String: AnyObject]?) -> Bool {
        guard let notification = notification else {
            return false
        }
        deviceDataManager?.servicesManager.handleRemoteNotification(notification)
        return true
    }
    
    // MARK: - Deeplinking
    
    func handle(_ url: URL) -> Bool {
        deeplinkManager.handle(url)
    }

    // MARK: - Continuity

    func userActivity(_ userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        if userActivity.activityType == NewCarbEntryIntent.className {
            log.default("Restoring %{public}@ intent", userActivity.activityType)
            rootViewController?.restoreUserActivityState(.forNewCarbEntry())
            return true
        }

        switch userActivity.activityType {
        case NSUserActivity.newCarbEntryActivityType,
             NSUserActivity.viewLoopStatusActivityType:
            log.default("Restoring %{public}@ activity", userActivity.activityType)
            if let rootViewController = rootViewController {
                restorationHandler([rootViewController])
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Interface

    private static let defaultSupportedInterfaceOrientations = UIInterfaceOrientationMask.allButUpsideDown

    var supportedInterfaceOrientations = defaultSupportedInterfaceOrientations {
        didSet {
            if #available(iOS 16.0, *) {
                rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            } else {
                // Fallback on earlier versions
            }
        }
    }

    // MARK: - Background Tasks

    private func registerBackgroundTasks() {
        if DeviceDataManager.registerCriticalEventLogHistoricalExportBackgroundTask({ self.deviceDataManager?.handleCriticalEventLogHistoricalExportBackgroundTask($0) }) {
            log.debug("Critical event log export background task registered")
        } else {
            log.error("Critical event log export background task not registered")
        }
    }

    private func scheduleBackgroundTasks() {
        deviceDataManager?.scheduleCriticalEventLogHistoricalExportBackgroundTask()
    }

    // MARK: - Private
    
    private func setWhitelistedDevices() {
        var whitelistedCGMs: Set<String> = []
        var whitelistedPumps: Set<String> = []
        
        supportManager.availableSupports.forEach {
            $0.deviceIdentifierWhitelist.cgmDevices.forEach({ whitelistedCGMs.insert($0) })
            $0.deviceIdentifierWhitelist.pumpDevices.forEach({ whitelistedPumps.insert($0) })
        }
        
        deviceDataManager.deviceWhitelist = DeviceWhitelist(cgmDevices: Array(whitelistedCGMs), pumpDevices: Array(whitelistedPumps))
    }

    private func isProtectedDataAvailable() -> Bool {
        let fileManager = FileManager.default
        do {
            let documentDirectory = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let fileURL = documentDirectory.appendingPathComponent("protection.test")
            guard fileManager.fileExists(atPath: fileURL.path) else {
                let contents = Data("unimportant".utf8)
                try? contents.write(to: fileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
                // If file doesn't exist, we're at first start, which will be user directed.
                return true
            }
            let contents = try? Data(contentsOf: fileURL)
            return contents != nil
        } catch {
            log.error("Could not create after first unlock test file: %@", String(describing: error))
        }
        return false
    }
    
    private var rootViewController: UIViewController? {
        get { windowProvider?.window?.rootViewController }
        set { windowProvider?.window?.rootViewController = newValue }
    }
}

// MARK: - AlertPresenter

extension LoopAppManager: AlertPresenter {
    func present(_ viewControllerToPresent: UIViewController, animated: Bool, completion: (() -> Void)?) {
        DispatchQueue.main.async {
            self.rootViewController?.topmostViewController.present(viewControllerToPresent, animated: animated, completion: completion)
        }
    }

    func dismissTopMost(animated: Bool, completion: (() -> Void)?) {
        rootViewController?.topmostViewController.dismiss(animated: animated, completion: completion)
    }

    func dismissAlert(_ alertToDismiss: UIAlertController, animated: Bool, completion: (() -> Void)?) {
        if rootViewController?.topmostViewController == alertToDismiss {
            dismissTopMost(animated: animated, completion: completion)
        } else {
            // check if the alert to dismiss is presenting another alert (and so on)
            // calling dismiss() on an alert presenting another alert will only dismiss the presented alert
            // (and any other alerts presented by the presented alert)

            // get the stack of presented alerts that would be undesirably dismissed
            var presentedAlerts: [UIAlertController] = []
            var currentAlert = alertToDismiss
            while let presentedAlert = currentAlert.presentedViewController as? UIAlertController {
                presentedAlerts.append(presentedAlert)
                currentAlert = presentedAlert
            }

            if presentedAlerts.isEmpty {
                alertToDismiss.dismiss(animated: animated, completion: completion)
            } else {
                // Do not animate any of these view transitions, since the alert to dismiss is not at the top of the stack

                // dismiss all the child presented alerts.
                // Calling dismiss() on a VC that is presenting an other VC will dismiss the presented VC and all of its child presented VCs
                alertToDismiss.dismiss(animated: false) {
                    // dismiss the desired alert
                    // Calling dismiss() on a VC that is NOT presenting any other VCs will dismiss said VC
                    alertToDismiss.dismiss(animated: false) {
                        // present the child alerts that were undesirably dismissed
                        var orderedPresentationBlock: (() -> Void)? = nil
                        for alert in presentedAlerts.reversed() {
                            if alert == presentedAlerts.last {
                                orderedPresentationBlock = {
                                    self.present(alert, animated: false, completion: completion)
                                }
                            } else {
                                orderedPresentationBlock = {
                                    self.present(alert, animated: false, completion: orderedPresentationBlock)
                                }
                            }
                        }
                        orderedPresentationBlock?()
                    }
                }
            }
        }
    }
}

// MARK: - DeviceOrientationController

extension LoopAppManager: DeviceOrientationController {
    func setDefaultSupportedInferfaceOrientations() {
        supportedInterfaceOrientations = Self.defaultSupportedInterfaceOrientations
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension LoopAppManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        switch notification.request.identifier {
        // TODO: Until these notifications are converted to use the new alert system, they shall still show in the foreground
        case LoopNotificationCategory.bolusFailure.rawValue,
             LoopNotificationCategory.pumpBatteryLow.rawValue,
             LoopNotificationCategory.pumpExpired.rawValue,
             LoopNotificationCategory.pumpFault.rawValue,
             LoopNotificationCategory.remoteBolus.rawValue,
             LoopNotificationCategory.remoteBolusFailure.rawValue,
             LoopNotificationCategory.remoteCarbs.rawValue,
             LoopNotificationCategory.remoteCarbsFailure.rawValue,
             LoopNotificationCategory.missedMeal.rawValue:
            completionHandler([.badge, .sound, .list, .banner])
        default:
            // For all others, banners are not to be displayed while in the foreground
            completionHandler([.badge, .sound, .list])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case NotificationManager.Action.retryBolus.rawValue:
            if  let units = response.notification.request.content.userInfo[LoopNotificationUserInfoKey.bolusAmount.rawValue] as? Double,
                let startDate = response.notification.request.content.userInfo[LoopNotificationUserInfoKey.bolusStartDate.rawValue] as? Date,
                let activationTypeRawValue = response.notification.request.content.userInfo[LoopNotificationUserInfoKey.bolusActivationType.rawValue] as? BolusActivationType.RawValue,
                let activationType = BolusActivationType(rawValue: activationTypeRawValue),
                startDate.timeIntervalSinceNow >= TimeInterval(minutes: -5)
            {
                deviceDataManager?.analyticsServicesManager.didRetryBolus()
                
                deviceDataManager?.enactBolus(units: units, activationType: activationType) { (_) in
                    DispatchQueue.main.async {
                        completionHandler()
                    }
                }
                return
            }
        case NotificationManager.Action.acknowledgeAlert.rawValue:
            let userInfo = response.notification.request.content.userInfo
            if let alertIdentifier = userInfo[LoopNotificationUserInfoKey.alertTypeID.rawValue] as? Alert.AlertIdentifier,
               let managerIdentifier = userInfo[LoopNotificationUserInfoKey.managerIDForAlert.rawValue] as? String {
                alertManager?.acknowledgeAlert(identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: alertIdentifier))
            }
        case UNNotificationDefaultActionIdentifier:
            guard response.notification.request.identifier == LoopNotificationCategory.missedMeal.rawValue else {
                break
            }

            let carbActivity = NSUserActivity.forNewCarbEntry()
            let userInfo = response.notification.request.content.userInfo
            
            if
                let mealTime = userInfo[LoopNotificationUserInfoKey.missedMealTime.rawValue] as? Date,
                let carbAmount = userInfo[LoopNotificationUserInfoKey.missedMealCarbAmount.rawValue] as? Double
            {
                let missedEntry = NewCarbEntry(quantity: HKQuantity(unit: .gram(),
                                                                         doubleValue: carbAmount),
                                                    startDate: mealTime,
                                                    foodType: nil,
                                                    absorptionTime: nil)
                carbActivity.update(from: missedEntry, isMissedMeal: true)
            }
            
            rootViewController?.restoreUserActivityState(carbActivity)
            
        default:
            break
        }

        completionHandler()
    }

}


// MARK: - UNUserNotificationCenterDelegate

extension LoopAppManager: TemporaryScheduleOverrideHistoryDelegate {
    func temporaryScheduleOverrideHistoryDidUpdate(_ history: TemporaryScheduleOverrideHistory) {
        UserDefaults.appGroup?.overrideHistory = history

        deviceDataManager.remoteDataServicesManager.triggerUpload(for: .overrides)
    }
}

extension LoopAppManager: ResetLoopManagerDelegate {
    func askUserToConfirmLoopReset() {
        resetLoopManager.askUserToConfirmLoopReset()
    }
    
    func presentConfirmationAlert(confirmAction: @escaping (PumpManager?, @escaping () -> Void) -> Void, cancelAction: @escaping () -> Void) {
        alertManager.presentLoopResetConfirmationAlert(
            confirmAction: { [weak self] completion in
                confirmAction(self?.deviceDataManager.pumpManager, completion)
            },
            cancelAction: cancelAction
        )
    }
    
    func loopWillReset() {
        supportManager.availableSupports.forEach { supportUI in
            supportUI.loopWillReset()
        }
    }
    
    func loopDidReset() {
        supportManager.availableSupports.forEach { supportUI in
            supportUI.loopDidReset()
        }
    }
    
    func resetTestingData(completion: @escaping () -> Void) {
        deviceDataManager.deleteTestingCGMData { [weak deviceDataManager] _ in
            deviceDataManager?.deleteTestingPumpData { _ in
                completion()
            }
        }
    }
    
    func presentCouldNotResetLoopAlert(error: Error) {
        alertManager.presentCouldNotResetLoopAlert(error: error)
    }
}
