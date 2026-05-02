//
//  HUDInterfaceController.swift
//  WatchApp Extension
//
//  Created by Bharat Mediratta on 6/29/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import WatchKit
import LoopCore
import LoopKit
import WatchAlgorithmKit  // for WatchAlgorithmDriver.warmUpDidCompleteNotification (B.6 Phase 4a-bis)

class HUDInterfaceController: WKInterfaceController {
    private var activeContextObserver: NSObjectProtocol?
    // B.3.a Phase 7: observer for warm-up completion
    private var warmUpObserver: NSObjectProtocol?

    @IBOutlet weak var loopHUDImage: WKInterfaceImage!
    @IBOutlet weak var glucoseLabel: WKInterfaceLabel!
    @IBOutlet weak var eventualGlucoseLabel: WKInterfaceLabel!

    var loopManager = ExtensionDelegate.shared().loopManager

    override func willActivate() {
        super.willActivate()

        update()
        updateWarmUpTitle()

        if activeContextObserver == nil {
            activeContextObserver = NotificationCenter.default.addObserver(forName: WatchContextManager.didUpdateContextNotification, object: loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.update()
                }
            }
        }

        // B.3.a Phase 7: clear "Loop warming up" title when first iteration completes.
        if warmUpObserver == nil {
            warmUpObserver = NotificationCenter.default.addObserver(
                forName: WatchAlgorithmDriver.warmUpDidCompleteNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateWarmUpTitle()
            }
        }

        loopManager.requestContextUpdate(completion: {
            self.loopManager.requestGlucoseBackfillIfNecessary()
        })
    }

    override func didDeactivate() {
        super.didDeactivate()

        if let observer = activeContextObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        activeContextObserver = nil
        // Note: warmUpObserver is kept alive across deactivations so the
        // title clears even if the controller is not the current page when
        // the first iteration completes.
    }

    // MARK: - B.3.a Phase 7: warm-up title

    /// Sets the controller's navigation-bar title to "Loop warming up" while
    /// the algorithm driver is in its warm-up window, and clears it once
    /// the first iteration completes (or if there is no active driver).
    private func updateWarmUpTitle() {
        let driver = ExtensionDelegate.shared().watchAlgorithmBootstrap?.driver
        if driver?.isWarmingUp == true {
            setTitle(NSLocalizedString("Loop warming up", comment: "Watch HUD title shown while algorithm stores are backfilling after handoff"))
        } else {
            setTitle(NSLocalizedString("Loop", comment: "Watch HUD default title"))
        }
    }

    func update() {
        guard let activeContext = loopManager.activeContext else {
            loopHUDImage.setHidden(true)
            return
        }
        loopHUDImage.setHidden(false)

        let date = activeContext.loopLastRunDate
        let isClosedLoop = activeContext.isClosedLoop ?? false
        loopHUDImage.setLoopImage(isClosedLoop: isClosedLoop, {
            if let date = date {
                switch date.timeIntervalSinceNow {
                case let t where t > .minutes(-6):
                    return .fresh
                case let t where t > .minutes(-20):
                    return .aging
                default:
                    return .stale
                }
            } else {
                return .unknown
            }
        }())

        if date != nil {
            glucoseLabel.setText(NSLocalizedString("– – –", comment: "No glucose value representation (3 dashes for mg/dL)"))
            glucoseLabel.setHidden(false)
            
            let showEventualGlucose = FeatureFlags.showEventualBloodGlucoseOnWatchEnabled
            if showEventualGlucose {
                eventualGlucoseLabel.setHidden(true)
            }
                
            if let glucose = activeContext.glucose, let glucoseDate = activeContext.glucoseDate, let unit = activeContext.displayGlucoseUnit, glucoseDate.timeIntervalSinceNow > -LoopCoreConstants.inputDataRecencyInterval {
                let formatter = NumberFormatter.glucoseFormatter(for: unit)
                
                if let glucoseValue = formatter.string(from: glucose.doubleValue(for: unit)) {
                    let trend = activeContext.glucoseTrend?.symbol ?? ""
                    glucoseLabel.setText(glucoseValue + trend)
                }
                
                if showEventualGlucose, let eventualGlucose = activeContext.eventualGlucose, let eventualGlucoseValue = formatter.string(from: eventualGlucose.doubleValue(for: unit)) {
                    eventualGlucoseLabel.setText(eventualGlucoseValue)
                    eventualGlucoseLabel.setHidden(false)
                }
            }
        }

    }

    @IBAction func addCarbs() {
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.carbEntry(nil))
    }
    
    func addCarbs(initialEntry: NewCarbEntry) {
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.carbEntry(initialEntry))
    }

    @IBAction func setBolus() {
        presentController(withName: CarbAndBolusFlowController.className, context: CarbAndBolusFlow.Configuration.manualBolus)
    }

}
