import XCTest
import LoopAlgorithmCore

final class LoopAlgorithmCoreImportTest: XCTestCase {
    func testImportWorks() {
        XCTAssertEqual(LoopAlgorithmCoreVersion.bundleVersion, "0.1.0-prerelease")
    }

    /// Compile-time + runtime check that the new Phase 2.D types are
    /// accessible from a cross-platform consumer (the watch test target). A
    /// stub conforming to LoopAlgorithmRunnerDelegate using only the
    /// default no-op implementations proves the protocol's public surface
    /// is reachable from watchOS.
    func testLoopAlgorithmRunnerDelegateProtocolIsAccessible() {
        final class StubDelegate: LoopAlgorithmRunnerDelegate {
            // Default impls cover everything; no overrides needed.
        }
        let stub = StubDelegate()
        XCTAssertNotNil(stub)
    }
}
