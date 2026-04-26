//
//  LoopAlgorithmCore.swift
//  LoopAlgorithmCore
//
//  Cross-platform framework hosting the stateful loop algorithm runner that
//  ties LoopKit's LoopAlgorithm actor + LoopMath + CarbMath + DoseMath into
//  a complete loop iteration.
//
//  iOS LoopDataManager and WatchAlgorithmDriver each construct a
//  LoopAlgorithmRunner and implement LoopAlgorithmRunnerDelegate to handle
//  platform-specific orchestration (LiveActivities, Widgets, NSNotifications
//  on iOS; watch UI updates on watchOS).
//
//  Phase 2.B: empty framework target.
//  Phase 2.C: relocated algorithm-only types live here.
//  Phase 2.D: LoopAlgorithmRunner + LoopAlgorithmRunnerDelegate added.
//
//  Part of B.3.a — see:
//    docs/superpowers/specs/2026-04-26-b3a-watch-self-driving-design.md
//    docs/research/2026-04-26-loopalgorithmcore-extraction.md
//

import Foundation
import LoopKit

/// Marker symbol so the framework has at least one public symbol.
/// Will be replaced by real types in Phase 2.C/2.D.
public enum LoopAlgorithmCoreVersion {
    public static let bundleVersion = "0.1.0-prerelease"
}
