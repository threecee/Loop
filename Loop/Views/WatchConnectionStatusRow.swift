//
//  WatchConnectionStatusRow.swift
//  Loop
//
//  One-row SwiftUI view in Loop's Settings showing the phone↔watch
//  connection state. Long-press triggers a debug echo.
//
//  NOTE: Spec §4.1 listed this as Loop/Views/Settings/WatchConnectionStatusRow.swift,
//  but Loop has no Settings/ subdirectory — its SettingsView.swift lives directly
//  under Loop/Views/. Following on-disk reality.
//

import SwiftUI

struct WatchConnectionStatusRow: View {
    @ObservedObject var coordinator: PhoneWatchSessionCoordinator
    @State private var echoResult: String?

    var body: some View {
        HStack {
            Text("Watch")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(coordinator.isConnected ? "connected" : "disconnected")
                    .foregroundStyle(coordinator.isConnected ? .green : .secondary)
                if let when = coordinator.lastHeartbeatReceivedAt {
                    Text(staleness(since: when))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let echo = echoResult {
                    Text(echo).font(.caption2).foregroundStyle(.blue)
                }
            }
        }
        .onLongPressGesture {
            echoResult = "echo…"
            coordinator.sendDebugEcho { result in
                switch result {
                case .success(let rtt):
                    echoResult = String(format: "echo %.0f ms", rtt * 1000)
                case .failure:
                    echoResult = "echo failed"
                }
                // Fade the message after 3 seconds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    echoResult = nil
                }
            }
        }
    }

    private func staleness(since: Date) -> String {
        let s = Int(-since.timeIntervalSinceNow)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}

/// Wrapper that resolves the shared coordinator at render time. Used in
/// SettingsView, which doesn't receive the coordinator directly via its
/// view model.
struct WatchConnectionStatusRowContainer: View {
    var body: some View {
        if let coordinator = PhoneWatchSessionCoordinator.shared {
            WatchConnectionStatusRow(coordinator: coordinator)
        } else {
            HStack {
                Text("Watch")
                Spacer()
                Text("not started")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
