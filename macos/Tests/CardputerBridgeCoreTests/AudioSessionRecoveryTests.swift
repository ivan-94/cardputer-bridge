import CardputerBridgeCore
import XCTest

final class AudioSessionRecoveryTests: XCTestCase {
    func testCandidateAuthenticationAllowsAFullRadioStallRecoveryWindow() {
        XCTAssertGreaterThanOrEqual(
            AudioSessionRecovery.candidateValidationTimeoutSeconds,
            3
        )
    }

    func testFailedOfferKeepsAStableEndpointLongEnoughForUdpRecovery() {
        XCTAssertGreaterThanOrEqual(
            AudioSessionRecovery.failedOfferRotationSeconds,
            15
        )
    }

    func testNewAppProcessOffersFreshSessionUntilItAuthenticatesAPacket() {
        XCTAssertTrue(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: true,
            wifiIsConnected: true,
            acceptedPacketCount: 0
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: true,
            wifiIsConnected: true,
            acceptedPacketCount: 1
        ))
    }

    func testSessionOfferWaitsForControlAndWifi() {
        XCTAssertFalse(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: false,
            wifiIsConnected: true,
            acceptedPacketCount: 0
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: true,
            wifiIsConnected: false,
            acceptedPacketCount: 0
        ))
    }

    func testRotatesSessionAfterDeviceRemainsNotReadyOnTheSameWifi() {
        XCTAssertTrue(AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: true,
            currentDeviceIsReady: false,
            wifiIsConnected: true,
            secondsContinuouslyNotReady: 5,
            settlementInterval: 5
        ))
    }

    func testDoesNotRotateDuringInitialConnectionOrWifiLoss() {
        XCTAssertFalse(AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: false,
            currentDeviceIsReady: false,
            wifiIsConnected: true,
            secondsContinuouslyNotReady: 30,
            settlementInterval: 5
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: true,
            currentDeviceIsReady: false,
            wifiIsConnected: false,
            secondsContinuouslyNotReady: 30,
            settlementInterval: 5
        ))
    }

    func testDoesNotRotateDuringTheExpectedNewOfferTransition() {
        XCTAssertFalse(AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: true,
            currentDeviceIsReady: false,
            wifiIsConnected: true,
            secondsContinuouslyNotReady: 1,
            settlementInterval: 5
        ))
    }

    func testRetryNeverReusesTheSameGCMStreamSession() {
        XCTAssertTrue(AudioSessionRecovery.shouldRotateFailedOffer(
            currentSessionID: 42,
            lastOfferedSessionID: 42,
            elapsedSeconds: 1.5,
            retryInterval: 1.5
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldRotateFailedOffer(
            currentSessionID: 43,
            lastOfferedSessionID: 42,
            elapsedSeconds: 2,
            retryInterval: 1.5
        ))
    }
}
