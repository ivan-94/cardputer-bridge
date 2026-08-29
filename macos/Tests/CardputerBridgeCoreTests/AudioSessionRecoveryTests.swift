import CardputerBridgeCore
import XCTest

final class AudioSessionRecoveryTests: XCTestCase {
    func testNewAppProcessOffersFreshSessionUntilItAuthenticatesAPacket() {
        XCTAssertTrue(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: true,
            wifiIsConnected: true,
            authenticatedPacketCount: 0
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: true,
            wifiIsConnected: true,
            authenticatedPacketCount: 1
        ))
    }

    func testSessionOfferWaitsForControlAndWifi() {
        XCTAssertFalse(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: false,
            wifiIsConnected: true,
            authenticatedPacketCount: 0
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldOfferSession(
            controlIsReady: true,
            wifiIsConnected: false,
            authenticatedPacketCount: 0
        ))
    }

    func testRotatesSessionWhenAReadyDeviceRebootsOnTheSameWifi() {
        XCTAssertTrue(AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: true,
            currentDeviceIsReady: false,
            wifiIsConnected: true
        ))
    }

    func testDoesNotRotateDuringInitialConnectionOrWifiLoss() {
        XCTAssertFalse(AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: false,
            currentDeviceIsReady: false,
            wifiIsConnected: true
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldRotateSession(
            previousDeviceWasReady: true,
            currentDeviceIsReady: false,
            wifiIsConnected: false
        ))
    }

    func testRotatesWhenDeviceIsWaitingButCurrentReceiverHasOldAuthenticatedPackets() {
        XCTAssertTrue(AudioSessionRecovery.shouldRotateStaleAuthenticatedSession(
            deviceAudioIsReady: false,
            wifiIsConnected: true,
            authenticatedPacketCount: 222
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldRotateStaleAuthenticatedSession(
            deviceAudioIsReady: true,
            wifiIsConnected: true,
            authenticatedPacketCount: 222
        ))
        XCTAssertFalse(AudioSessionRecovery.shouldRotateStaleAuthenticatedSession(
            deviceAudioIsReady: false,
            wifiIsConnected: true,
            authenticatedPacketCount: 0
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
