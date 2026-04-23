//
//  WatchHandoffEventLogView.swift
//  Loop
//
//  Scrollable view of the last 10 handoff transitions from the state machine.
//

import SwiftUI
import OmniBLE

struct WatchHandoffEventLogView: View {
    @ObservedObject var orchestrator: HandoffOrchestrator

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }()

    var body: some View {
        List(orchestrator.transitionLog.reversed(), id: \.timestamp) { record in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Self.timeFormatter.string(from: record.timestamp))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text("\(record.from.rawValue) → \(record.to.rawValue)")
                        .font(.caption)
                }
                Text("(\(record.trigger.rawValue))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("Recent activity")
    }
}
