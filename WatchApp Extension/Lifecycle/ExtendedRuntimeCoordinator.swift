import Foundation
import SwiftUI
import WatchKit
import Combine
import OmniBLE

/// Narrow protocol to keep the coordinator testable without a real WKExtendedRuntimeSession.
protocol ExtendedRuntimeSessionProtocol {
    func start()
    func invalidate()
}

extension WKExtendedRuntimeSession: ExtendedRuntimeSessionProtocol {}

/// Manages the lifecycle of a WKExtendedRuntimeSession. The session is active
/// only while BOTH conditions hold: the app scene is `.active` AND the watch
/// is the current handoff driver. When either condition is false, the session
/// is invalidated so the OS can reclaim the runtime budget.
///
/// B.9 efficiency #6: previously the session started unconditionally on every
/// scene `.active` transition. When phone is the driver, the watch is just a
/// viewer — the runtime budget was wasted. Gate on
/// `HandoffOrchestrator.handoffState == .watchDriver`.
///
/// Note: WKExtendedRuntimeSession has category limits (e.g., max duration).
/// For a glucose reader, category `.background` is the correct choice —
/// it supports continuous-background use for tracking.
final class ExtendedRuntimeCoordinator {
    private var currentSession: ExtendedRuntimeSessionProtocol?
    private let sessionFactory: () -> ExtendedRuntimeSessionProtocol

    /// Latest scene phase observed via `onScenePhaseChange(_:)`. The session is
    /// only kept alive while this is `.active`.
    private var lastScenePhase: ScenePhase = .background

    /// Whether the watch currently owns dosing per the handoff orchestrator.
    /// Updated via the Combine subscription wired by `bind(to:)` (or
    /// `bindHandoffStatePublisher(_:)` in tests).
    private var isWatchDriver: Bool = false

    private var ownershipCancellable: AnyCancellable?

    init(sessionFactory: @escaping () -> ExtendedRuntimeSessionProtocol = {
        WKExtendedRuntimeSession()
    }) {
        self.sessionFactory = sessionFactory
    }

    /// Wire up the Combine subscription against an existing HandoffOrchestrator.
    /// Called by ExtensionDelegate after the orchestrator is constructed.
    @MainActor
    func bind(to orchestrator: HandoffOrchestrator) {
        bindHandoffStatePublisher(orchestrator.$handoffState.eraseToAnyPublisher())
    }

    /// Test seam: bind to an arbitrary publisher of HandoffState.
    func bindHandoffStatePublisher(_ publisher: AnyPublisher<HandoffState, Never>) {
        ownershipCancellable = publisher
            .map { state -> Bool in
                if case .watchDriver = state { return true }
                return false
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isWatchDriver in
                self?.isWatchDriver = isWatchDriver
                self?.applyState()
            }
    }

    func onScenePhaseChange(_ phase: ScenePhase) {
        lastScenePhase = phase
        applyState()
    }

    /// Single source of truth: session runs iff scene is active AND watch is driver.
    private func applyState() {
        let shouldRun = (lastScenePhase == .active) && isWatchDriver
        if shouldRun {
            if currentSession == nil {
                let s = sessionFactory()
                s.start()
                currentSession = s
            }
        } else {
            currentSession?.invalidate()
            currentSession = nil
        }
    }
}
