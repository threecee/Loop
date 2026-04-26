//
//  LoopWarmingUpBadge.swift
//  WatchApp Extension
//
//  Small badge shown on the watch during the first ~5-30 min after handoff
//  while LoopAlgorithmRunner's CoreData stores backfill from the G7 sensor
//  and pod history. Algorithm produces conservative decisions during warm-up;
//  this badge tells the user "we know predictions are limited; that's normal."
//
//  This view is rendered via WKHostingController when needed in WatchKit
//  contexts, or used directly in future SwiftUI-based watch UIs.
//
//  B.3.a Phase 7.
//

import SwiftUI

struct LoopWarmingUpBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass")
                .font(.caption2)
            Text("Loop warming up")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.2))
        .clipShape(Capsule())
        .accessibilityLabel(Text("Loop is warming up. Predictions may be limited for the first 30 minutes."))
    }
}

#Preview {
    LoopWarmingUpBadge()
}
