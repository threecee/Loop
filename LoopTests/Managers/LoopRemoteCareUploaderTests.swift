//
//  LoopRemoteCareUploaderTests.swift
//  LoopTests
//
//  B.11.1 Phase 3: tests for the iOS conformer of RemoteCareUploader.
//

import XCTest
import OmniBLE
@testable import Loop

final class LoopRemoteCareUploaderTests: XCTestCase {

    /// Captures the RemoteDataType values forwarded to the underlying
    /// `RemoteDataServicesManager.triggerUpload(for:)`. Used as a stand-in
    /// for RDSM in unit tests.
    final class MockRDSMTrigger {
        var calls: [RemoteDataType] = []
        func triggerUpload(for type: RemoteDataType) {
            calls.append(type)
        }
    }

    func testUploadForwardsToUnderlyingRDSM() {
        let mock = MockRDSMTrigger()
        let uploader = LoopRemoteCareUploader(triggerUpload: mock.triggerUpload(for:))

        uploader.upload(for: .glucose)
        uploader.upload(for: .dosingDecision)

        XCTAssertEqual(mock.calls, [.glucose, .dosingDecision])
    }

    func testUploadTypeMappingIsExhaustive() {
        // Every RemoteCareUploadType case must map to a RemoteDataType case.
        // Failing this test means a new case was added to one enum without
        // updating the wrapper's mapping function.
        let mock = MockRDSMTrigger()
        let uploader = LoopRemoteCareUploader(triggerUpload: mock.triggerUpload(for:))

        for type in RemoteCareUploadType.allCases {
            uploader.upload(for: type)
        }

        XCTAssertEqual(mock.calls.count, RemoteCareUploadType.allCases.count)
    }

    func testQuiescedUploadIsNoOp() {
        let mock = MockRDSMTrigger()
        let uploader = LoopRemoteCareUploader(triggerUpload: mock.triggerUpload(for:))

        uploader.quiesce()
        XCTAssertTrue(uploader.isQuiesced)

        uploader.upload(for: .glucose)
        uploader.upload(for: .dose)

        XCTAssertEqual(mock.calls, [], "Uploads must be no-ops while quiesced")
    }

    func testResumeReenablesUploads() {
        let mock = MockRDSMTrigger()
        let uploader = LoopRemoteCareUploader(triggerUpload: mock.triggerUpload(for:))

        uploader.quiesce()
        uploader.upload(for: .glucose)  // dropped
        uploader.resume()
        XCTAssertFalse(uploader.isQuiesced)

        uploader.upload(for: .glucose)  // forwarded

        XCTAssertEqual(mock.calls, [.glucose])
    }

    func testQuiesceAndResumeAreIdempotent() {
        let mock = MockRDSMTrigger()
        let uploader = LoopRemoteCareUploader(triggerUpload: mock.triggerUpload(for:))

        uploader.quiesce()
        uploader.quiesce()  // no crash, no state corruption
        XCTAssertTrue(uploader.isQuiesced)

        uploader.resume()
        uploader.resume()  // no crash
        XCTAssertFalse(uploader.isQuiesced)
    }
}
