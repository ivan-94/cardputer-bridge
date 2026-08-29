import XCTest
@testable import CardputerBridgeCore

final class BridgeReducerTests: XCTestCase {
    func testHeartbeatWatchdogOnlyResetsAStalledInFlightWrite() {
        XCTAssertFalse(
            HeartbeatWriteWatchdog.shouldReset(
                writeInFlight: false,
                elapsedSeconds: 10,
                timeoutSeconds: 2
            )
        )
        XCTAssertFalse(
            HeartbeatWriteWatchdog.shouldReset(
                writeInFlight: true,
                elapsedSeconds: 1.99,
                timeoutSeconds: 2
            )
        )
        XCTAssertTrue(
            HeartbeatWriteWatchdog.shouldReset(
                writeInFlight: true,
                elapsedSeconds: 2,
                timeoutSeconds: 2
            )
        )
    }

    func testSetMicIntentUsesTheVersionedIdempotentControlEnvelope() throws {
        let message = SetMicIntentMessage(
            id: "request-1",
            sentAtMilliseconds: 123,
            intent: .live
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try message.encoded()) as? [String: Any]
        )
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["id"] as? String, "request-1")
        XCTAssertEqual(object["type"] as? String, "set_mic_intent")
        XCTAssertEqual(object["sent_at_ms"] as? Int, 123)
        XCTAssertEqual(
            (object["body"] as? [String: Any])?["intent"] as? String,
            "live"
        )
    }

    func testHeartbeatUsesTheVersionedControlEnvelope() throws {
        let message = HeartbeatMessage(
            id: "heartbeat-1",
            sentAtMilliseconds: 456,
            intent: .live
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try message.encoded()) as? [String: Any]
        )
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["id"] as? String, "heartbeat-1")
        XCTAssertEqual(object["type"] as? String, "heartbeat")
        XCTAssertEqual(object["sent_at_ms"] as? Int, 456)
        XCTAssertEqual(
            (object["body"] as? [String: Any])?["intent"] as? String,
            "live"
        )
    }

    func testBluetoothPowerOnStartsDeviceDiscovery() {
        var reducer = BLESessionReducer()

        let effects = reducer.dispatch(.radioChanged(.poweredOn))

        XCTAssertEqual(reducer.state.phase, .scanning)
        XCTAssertEqual(effects, [.startScan])
    }

    func testDiscoveryStopsScanningAndExposesTheRealDevice() {
        var reducer = BLESessionReducer()
        reducer.dispatch(.radioChanged(.poweredOn))

        let effects = reducer.dispatch(
            .deviceDiscovered(id: "device-1", name: "Cardputer Bridge")
        )

        XCTAssertEqual(reducer.state.phase, .deviceFound)
        XCTAssertEqual(reducer.state.device?.id, "device-1")
        XCTAssertEqual(reducer.state.device?.name, "Cardputer Bridge")
        XCTAssertEqual(effects, [.stopScan])
    }

    func testConnectionBecomesReadyOnlyAfterEncryptedIdentityIsRead() {
        var reducer = BLESessionReducer()
        reducer.dispatch(.radioChanged(.poweredOn))
        reducer.dispatch(.deviceDiscovered(id: "device-1", name: "Cardputer Bridge"))

        XCTAssertEqual(
            reducer.dispatch(.connectRequested),
            [.connect(deviceID: "device-1")]
        )
        XCTAssertEqual(reducer.state.phase, .connecting)

        XCTAssertEqual(reducer.dispatch(.connected), [.discoverVendorService])
        XCTAssertEqual(reducer.state.phase, .discoveringServices)

        XCTAssertEqual(
            reducer.dispatch(.vendorCharacteristicsReady),
            [.requestEncryptedIdentityAndSubscribe]
        )
        XCTAssertEqual(reducer.state.phase, .authenticating)

        XCTAssertEqual(
            reducer.dispatch(.identityRead("Cardputer-ADV")),
            []
        )
        XCTAssertEqual(reducer.state.phase, .ready)
        XCTAssertEqual(reducer.state.identity, "Cardputer-ADV")
        XCTAssertTrue(reducer.state.canSendCommand)
    }

    func testDisconnectClearsAuthorizationAndRestartsDiscovery() {
        var reducer = BLESessionReducer(
            state: BLESessionState(
                radio: .poweredOn,
                phase: .ready,
                device: BLEDevice(id: "device-1", name: "Cardputer Bridge"),
                identity: "Cardputer-ADV"
            )
        )

        let effects = reducer.dispatch(.disconnected(reason: "link lost"))

        XCTAssertEqual(reducer.state.phase, .scanning)
        XCTAssertNil(reducer.state.identity)
        XCTAssertFalse(reducer.state.canSendCommand)
        XCTAssertEqual(reducer.state.fault, "link lost")
        XCTAssertEqual(effects, [.startScan])
    }

    func testRediscoveredKnownDeviceReconnectsWithoutAnotherUserClick() {
        var reducer = BLESessionReducer()
        reducer.dispatch(.radioChanged(.poweredOn))

        let effects = reducer.dispatch(
            .knownDeviceRediscovered(id: "device-1", name: "Cardputer Bridge")
        )

        XCTAssertEqual(reducer.state.phase, .connecting)
        XCTAssertEqual(reducer.state.device?.id, "device-1")
        XCTAssertEqual(
            effects,
            [.stopScan, .connect(deviceID: "device-1")]
        )
    }

    func testBluetoothDeniedIsBlockingAndNeverPretendsToScan() {
        var reducer = BLESessionReducer(
            state: BLESessionState(
                radio: .poweredOn,
                phase: .ready,
                device: BLEDevice(id: "device-1", name: "Cardputer Bridge"),
                identity: "Cardputer-ADV"
            )
        )

        let effects = reducer.dispatch(.radioChanged(.unauthorized))

        XCTAssertEqual(reducer.state.phase, .blocked)
        XCTAssertNil(reducer.state.identity)
        XCTAssertEqual(reducer.state.fault, "bluetooth_unauthorized")
        XCTAssertEqual(effects, [])
    }

    func testProtocolMismatchFailsWithoutAnInfiniteReconnectLoop() {
        var reducer = BLESessionReducer(
            state: BLESessionState(
                radio: .poweredOn,
                phase: .discoveringServices,
                device: BLEDevice(id: "device-1", name: "Cardputer Bridge")
            )
        )

        let effects = reducer.dispatch(.failed(reason: "vendor_service_missing"))

        XCTAssertEqual(reducer.state.phase, .failed)
        XCTAssertEqual(reducer.state.fault, "vendor_service_missing")
        XCTAssertEqual(effects, [])
    }

    func testUserRetryClearsFailureAndRestartsDiscovery() {
        var reducer = BLESessionReducer(
            state: BLESessionState(
                radio: .poweredOn,
                phase: .failed,
                device: BLEDevice(id: "device-1", name: "Cardputer Bridge"),
                fault: "ble_connect_failed"
            )
        )

        let effects = reducer.dispatch(.retryRequested)

        XCTAssertEqual(reducer.state.phase, .scanning)
        XCTAssertNil(reducer.state.device)
        XCTAssertNil(reducer.state.fault)
        XCTAssertEqual(effects, [.startScan])
    }

    func testServiceChangeReDiscoversCharacteristicsOnTheExistingConnection() {
        var reducer = BLESessionReducer(
            state: BLESessionState(
                radio: .poweredOn,
                phase: .failed,
                device: BLEDevice(id: "device-1", name: "Cardputer Bridge"),
                fault: "vendor_characteristics_missing"
            )
        )

        let effects = reducer.dispatch(.servicesInvalidated)

        XCTAssertEqual(reducer.state.phase, .discoveringServices)
        XCTAssertNil(reducer.state.fault)
        XCTAssertEqual(effects, [.discoverVendorService])
    }

    func testToggleOnlyOpensCaptureWhenAllAuthoritiesAreReady() {
        var reducer = BridgeReducer(state: .pairedNoWiFi)

        reducer.dispatch(.toggleMicIntent, source: .harness)

        XCTAssertEqual(reducer.state.micIntent, .live)
        XCTAssertEqual(reducer.state.captureGate, .closed)

        reducer.reset(to: .readyMuted)
        reducer.dispatch(.toggleMicIntent, source: .harness)

        XCTAssertEqual(reducer.state.micIntent, .live)
        XCTAssertEqual(reducer.state.captureGate, .open)
    }

    func testControlLossFailsClosedAndClearsLiveIntent() {
        var reducer = BridgeReducer(state: .readyMuted)
        reducer.dispatch(.toggleMicIntent, source: .harness)

        reducer.dispatch(.controlLinkLost, source: .bleControl)

        XCTAssertFalse(reducer.state.bleAuthorized)
        XCTAssertEqual(reducer.state.micIntent, .muted)
        XCTAssertEqual(reducer.state.captureGate, .closed)
    }
}
