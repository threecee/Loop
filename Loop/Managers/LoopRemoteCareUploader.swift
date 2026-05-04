//
//  LoopRemoteCareUploader.swift
//  Loop
//
//  B.11.1: iOS conformer of OmniBLE's RemoteCareUploader protocol.
//  Thin wrapper over Loop's RemoteDataServicesManager.triggerUpload(for:)
//  with quiesce/resume support. Lives in the Loop module (not OmniBLE)
//  because it translates RemoteCareUploadType <-> RemoteDataType, and
//  RemoteDataType is Loop-internal.
//
//  Role-gating is NOT performed here — that's HandoffOrchestrator's job
//  via its proxy method. This wrapper is a pure mechanism + quiesce flag.
//

import Foundation
import OmniBLE  // for RemoteCareUploader, RemoteCareUploadType
import os.log

final class LoopRemoteCareUploader: RemoteCareUploader {

    /// Closure injection over the underlying RDSM trigger. Closure form
    /// (rather than holding a strong RDSM reference) keeps the wrapper
    /// testable in isolation and avoids a retain cycle with
    /// DeviceDataManager (which owns RDSM).
    private let triggerUpload: (RemoteDataType) -> Void

    private let lock = NSLock()
    private var _isQuiesced: Bool = false

    private let log = OSLog(subsystem: "com.loopkit.Loop", category: "LoopRemoteCareUploader")

    init(triggerUpload: @escaping (RemoteDataType) -> Void) {
        self.triggerUpload = triggerUpload
    }

    var isQuiesced: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isQuiesced
    }

    func upload(for type: RemoteCareUploadType) {
        lock.lock()
        let quiesced = _isQuiesced
        lock.unlock()

        guard !quiesced else {
            os_log(.debug, log: log,
                   "upload(for: %{public}@) skipped: uploader quiesced",
                   type.rawValue)
            return
        }

        triggerUpload(Self.map(type))
    }

    func quiesce() {
        lock.lock()
        _isQuiesced = true
        lock.unlock()
        os_log(.default, log: log, "quiesced")
    }

    func resume() {
        lock.lock()
        _isQuiesced = false
        lock.unlock()
        os_log(.default, log: log, "resumed")
    }

    /// 1:1 mapping from the OmniBLE-public type to Loop's internal type.
    /// New cases added to either enum MUST be added here too — the
    /// `testUploadTypeMappingIsExhaustive` test catches mismatches.
    private static func map(_ type: RemoteCareUploadType) -> RemoteDataType {
        switch type {
        case .alert: return .alert
        case .carb: return .carb
        case .dose: return .dose
        case .dosingDecision: return .dosingDecision
        case .glucose: return .glucose
        case .pumpEvent: return .pumpEvent
        case .cgmEvent: return .cgmEvent
        case .settings: return .settings
        case .overrides: return .overrides
        }
    }
}
