import CardputerBridgeCore
import XCTest

final class GATTWriteArbitrationTests: XCTestCase {
    func testHeartbeatWaitsForTheControlTransactionToDrain() {
        XCTAssertFalse(GATTWriteArbitration.canStartHeartbeat(
            commandWriteInFlight: true,
            commandQueueDepth: 0
        ))
        XCTAssertFalse(GATTWriteArbitration.canStartHeartbeat(
            commandWriteInFlight: false,
            commandQueueDepth: 3
        ))
        XCTAssertTrue(GATTWriteArbitration.canStartHeartbeat(
            commandWriteInFlight: false,
            commandQueueDepth: 0
        ))
    }

    func testControlTransactionWaitsForHeartbeatAcknowledgement() {
        XCTAssertFalse(GATTWriteArbitration.canStartCommand(
            heartbeatWriteInFlight: true
        ))
        XCTAssertTrue(GATTWriteArbitration.canStartCommand(
            heartbeatWriteInFlight: false
        ))
    }
}
