import XCTest
@testable import CardputerBridgeCore

final class ConnectionRecoveryGuidanceTests: XCTestCase {
    func testSecurePairingFailureRecommendsRemovingTheOldBond() {
        XCTAssertEqual(
            ConnectionRecoveryGuidance.classify(
                fault: "secure_pairing_failed_15"
            ),
            .stalePairing
        )
    }

    func testMissingVendorServiceRecommendsReinstallingFirmware() {
        XCTAssertEqual(
            ConnectionRecoveryGuidance.classify(
                fault: "vendor_service_missing"
            ),
            .firmware
        )
        XCTAssertEqual(
            ConnectionRecoveryGuidance.classify(
                fault: "vendor_characteristics_missing"
            ),
            .firmware
        )
    }

    func testUnknownConnectionFailureUsesGeneralTroubleshooting() {
        XCTAssertEqual(
            ConnectionRecoveryGuidance.classify(
                fault: "The connection has timed out."
            ),
            .general
        )
        XCTAssertEqual(
            ConnectionRecoveryGuidance.classify(fault: nil),
            .general
        )
    }
}
