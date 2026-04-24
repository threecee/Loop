import Foundation
import SwiftUI
import WatchKit

/// Narrow protocol to keep the coordinator testable without a real WKExtendedRuntimeSession.
protocol ExtendedRuntimeSessionProtocol {
    func start()
    func invalidate()
}

extension WKExtendedRuntimeSession: ExtendedRuntimeSessionProtocol {}

/// Manages the lifecycle of a WKExtendedRuntimeSession. When the app scene
/// becomes `.active`, we start a session so BLE delivery remains reliable
/// during active use. On transition to `.background`, we invalidate so the
/// OS can reclaim resources.
///
/// Note: WKExtendedRuntimeSession has category limits (e.g., max duration).
/// For a glucose reader, category `.background` is the correct choice —
/// it supports continuous-background use for tracking.
final class ExtendedRuntimeCoordinator {
    private var currentSession: ExtendedRuntimeSessionProtocol?
    private let sessionFactory: () -> ExtendedRuntimeSessionProtocol

    init(sessionFactory: @escaping () -> ExtendedRuntimeSessionProtocol = {
        WKExtendedRuntimeSession()
    }) {
        self.sessionFactory = sessionFactory
    }

    func onScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if currentSession == nil {
                let s = sessionFactory()
                s.start()
                currentSession = s
            }
        case .background, .inactive:
            currentSession?.invalidate()
            currentSession = nil
        @unknown default:
            break
        }
    }
}
