//
//  WatchHandoffSection.swift
//  Loop
//
//  Settings section for B.2.d's bonding-handoff configuration + state.
//  Shows current state, mode picker (with BETA warning), manual trigger
//  button (gated to current state), and recent transition log.
//
//  NOTE: Spec §4.1 listed this as Loop/Views/Settings/WatchHandoffSection.swift,
//  but Loop has no Settings/ subdirectory — its SettingsView.swift lives directly
//  under Loop/Views/. Following on-disk reality (consistent with B.2.c's
//  WatchConnectionStatusRow.swift placement).
//

import SwiftUI
import OmniBLE

struct WatchHandoffSection: View {
    @ObservedObject var orchestrator: HandoffOrchestrator

    var body: some View {
        Section("Watch Handoff") {
            currentStateRow
            manualTriggerButton
            NavigationLink("Recent activity") {
                WatchHandoffEventLogView(orchestrator: orchestrator)
            }
            Link("How handoff works",
                 destination: URL(string: "https://threecee.github.io/myloop-watch-dynamics")!)
        }
    }

    @ViewBuilder
    private var currentStateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Current state")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(stateDescription)
                .font(.body)
                .foregroundStyle(stateColor)
            if case .recovering = orchestrator.handoffState {
                Button("Dismiss") {
                    orchestrator.dismissRecovering()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var manualTriggerButton: some View {
        switch orchestrator.handoffState {
        case .phoneDriver:
            Button("Hand off to Watch") {
                orchestrator.userRequestHandoff(to: .watch)
            }
        case .watchDriver:
            Button("Take back from Watch") {
                orchestrator.userRequestHandoff(to: .phone)
            }
        case .handoffPending, .recovering:
            EmptyView()
        }
    }

    private var stateDescription: String {
        switch orchestrator.handoffState {
        case .phoneDriver: return "Phone is driving"
        case .watchDriver: return "Watch is driving"
        case .handoffPending(let direction, _, _):
            return direction == .phoneToWatch
                ? "Handing off to watch…"
                : "Taking back from watch…"
        case .recovering(let reason, _):
            return "⚠ Recovering — \(reason)"
        }
    }

    private var stateColor: Color {
        switch orchestrator.handoffState {
        case .phoneDriver, .watchDriver: return .primary
        case .handoffPending: return .orange
        case .recovering: return .red
        }
    }
}

/// Wrapper that resolves the shared orchestrator at render time. Same pattern
/// as WatchConnectionStatusRowContainer.
struct WatchHandoffSectionContainer: View {
    var body: some View {
        if let orchestrator = HandoffOrchestrator.shared {
            WatchHandoffSection(orchestrator: orchestrator)
        } else {
            Section("Watch Handoff") {
                HStack {
                    Text("Watch Handoff")
                    Spacer()
                    Text("not started")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
