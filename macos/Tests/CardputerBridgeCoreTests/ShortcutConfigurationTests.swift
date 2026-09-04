import XCTest
@testable import CardputerBridgeCore

final class ShortcutConfigurationTests: XCTestCase {
    func testDefaultsMatchFirmwareCanonicalFormat() throws {
        let bytes = try BridgeShortcutConfiguration.defaults.canonicalData()

        XCTAssertEqual(125, bytes.count)
        XCTAssertEqual(Data([0x43, 0x42, 3, 4]), bytes.prefix(4))
        XCTAssertEqual(2, bytes[11])
        XCTAssertEqual(1, bytes[28])
        XCTAssertEqual(0, bytes[29])
        XCTAssertEqual(0x14, bytes[30])
        XCTAssertEqual(0x09, bytes[31])
        XCTAssertEqual("Quit", String(data: bytes[35..<39], encoding: .utf8))
    }

    func testArbitraryPhysicalChordsAndG0AloneAreValidTriggers() throws {
        var config = BridgeShortcutConfiguration.defaults
        config.schemaVersion = 3
        config.mappings = [
            .init(
                triggerUsage: 0x14,
                triggerModifiers: 0x01,
                triggerIncludesG0: false,
                modifiers: 0x09,
                outputUsage: 0x14,
                label: "Control Q"
            ),
            .init(
                triggerUsage: 0,
                triggerModifiers: 0,
                triggerIncludesG0: true,
                modifiers: 0x08,
                outputUsage: 0x2c,
                label: "Voice Input"
            ),
        ]

        XCTAssertNoThrow(try config.validated())
        let bytes = try config.canonicalData()
        XCTAssertEqual(Data([0x00, 0x01, 0x14]), bytes[28..<31])
        let secondOffset = 60
        XCTAssertEqual(Data([0x01, 0x00, 0x00]), bytes[secondOffset..<(secondOffset + 3)])
    }

    func testDuplicateValidationUsesTheWholePhysicalChord() throws {
        var config = BridgeShortcutConfiguration.defaults
        config.schemaVersion = 3
        config.mappings = [
            .init(triggerUsage: 0x14, triggerModifiers: 0, triggerIncludesG0: false,
                  modifiers: 0x08, outputUsage: 0x14, label: "Q"),
            .init(triggerUsage: 0x14, triggerModifiers: 0x01, triggerIncludesG0: false,
                  modifiers: 0x08, outputUsage: 0x14, label: "Control Q"),
        ]
        XCTAssertNoThrow(try config.validated())

        config.mappings[1].triggerModifiers = 0
        XCTAssertThrowsError(try config.validated()) { error in
            XCTAssertEqual(.duplicateTrigger, error as? ShortcutConfigurationError)
        }
    }

    func testLegacyJSONMigratesItsImplicitG0Layer() throws {
        let json = #"{"schemaVersion":1,"configVersion":7,"deviceID":"Cardputer-ADV","mappings":[{"id":"00000000-0000-0000-0000-000000000001","triggerUsage":20,"modifiers":9,"outputUsage":20,"label":"Quit","isEnabled":true}],"updatedAt":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BridgeShortcutConfiguration.self, from: json)

        XCTAssertTrue(decoded.mappings[0].triggerIncludesG0)
        XCTAssertEqual(0, decoded.mappings[0].triggerModifiers)
        XCTAssertEqual(3, decoded.migratedToCurrentSchema().schemaVersion)
    }

    func testPhysicalLearningMessagesAreTokenBound() throws {
        let start = try ShortcutLearnControlMessage(
            action: .start,
            token: 0x1234_5678
        ).encoded()
        XCTAssertLessThanOrEqual(start.count, 160)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: start) as? [String: Any]
        )
        XCTAssertEqual("shortcut_learn_start", object["type"] as? String)
        XCTAssertEqual(0x1234_5678, object["token"] as? Int)

        let event = ShortcutLearnEvent.decode(from: #"{"v":1,"event":"shortcut_learned","token":305419896,"g0":true,"mods":1,"usage":20}"#.data(using: .utf8)!)
        XCTAssertEqual(.captured, event?.event)
        XCTAssertEqual(0x1234_5678, event?.token)
        XCTAssertEqual(true, event?.includesG0)
        XCTAssertEqual(1, event?.modifiers)
        XCTAssertEqual(20, event?.usage)
    }

    func testShortcutTriggeredEventPreservesBothChords() throws {
        let data = #"{"v":1,"event":"shortcut_triggered","g0":true,"tmods":1,"tusage":20,"omods":9,"ousage":20}"#.data(using: .utf8)!
        let event = try XCTUnwrap(ShortcutTriggeredEvent.decode(from: data))

        XCTAssertTrue(event.includesG0)
        XCTAssertEqual(1, event.triggerModifiers)
        XCTAssertEqual(20, event.triggerUsage)
        XCTAssertEqual(9, event.outputModifiers)
        XCTAssertEqual(20, event.outputUsage)
    }

    func testDeviceTelemetryRejectsInvalidBatteryAndDecodesRSSI() throws {
        let valid = #"{"v":1,"event":"telemetry","bat":78,"rssi":-53,"ext":true,"sent":42,"fail":2,"overrun":3,"mf":2,"rd":1,"rh":4,"cg":23,"tg":137,"wd":4,"wr":200}"#.data(using: .utf8)!
        let snapshot = try XCTUnwrap(DeviceTelemetry.decode(from: valid))
        XCTAssertEqual(78, snapshot.batteryPercent)
        XCTAssertEqual(-53, snapshot.wifiRSSI)
        XCTAssertTrue(snapshot.externalPower)
        XCTAssertEqual(42, snapshot.streamFramesSent)
        XCTAssertEqual(2, snapshot.streamFailures)
        XCTAssertEqual(3, snapshot.captureOverruns)
        XCTAssertEqual(2, snapshot.microphoneRecordFailures)
        XCTAssertEqual(1, snapshot.captureRingDrops)
        XCTAssertEqual(4, snapshot.captureRingHighWater)
        XCTAssertEqual(23, snapshot.maximumCaptureGapMilliseconds)
        XCTAssertEqual(137, snapshot.maximumTransportGapMilliseconds)
        XCTAssertEqual(4, snapshot.wifiDisconnectCount)
        XCTAssertEqual(200, snapshot.lastWiFiDisconnectReason)

        let legacy = #"{"v":1,"event":"telemetry","bat":78,"rssi":-53}"#.data(using: .utf8)!
        XCTAssertFalse(try XCTUnwrap(DeviceTelemetry.decode(from: legacy)).externalPower)

        let invalid = #"{"v":1,"event":"telemetry","bat":101,"rssi":-53}"#.data(using: .utf8)!
        XCTAssertNil(DeviceTelemetry.decode(from: invalid))
    }

    func testTransferIsBoundedHashBoundAndReconstructsCanonicalBytes() throws {
        var config = BridgeShortcutConfiguration.defaults
        config.configVersion = 7
        let writes = try config.encodedTransferWrites()

        XCTAssertGreaterThanOrEqual(writes.count, 3)
        XCTAssertTrue(writes.allSatisfy { $0.count <= 160 })
        let prepare = try XCTUnwrap(
            JSONSerialization.jsonObject(with: writes[0]) as? [String: Any]
        )
        XCTAssertEqual("0000000000000007", prepare["ver"] as? String)
        XCTAssertNotNil(prepare["sha"] as? String)
        let chunkObjects = try writes.dropFirst().dropLast().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let reconstructed = chunkObjects.reduce(into: Data()) { result, object in
            result.append(Data(base64Encoded: object["data"] as! String)!)
        }
        XCTAssertEqual(try config.canonicalData(), reconstructed)
    }

    func testRejectsDuplicateTriggersAndOversizedLabels() throws {
        var config = BridgeShortcutConfiguration.defaults
        config.mappings.append(config.mappings[0])
        config.mappings[config.mappings.count - 1].id = UUID()
        XCTAssertThrowsError(try config.canonicalData()) { error in
            XCTAssertEqual(.duplicateTrigger, error as? ShortcutConfigurationError)
        }
        config = .defaults
        config.mappings[0].label = String(repeating: "a", count: 33)
        XCTAssertThrowsError(try config.canonicalData()) { error in
            XCTAssertEqual(.labelTooLong, error as? ShortcutConfigurationError)
        }
    }

    func testRejectsDuplicateIdentifiers() {
        var config = BridgeShortcutConfiguration.defaults
        var duplicate = config.mappings[0]
        duplicate.triggerUsage = 0x07
        config.mappings.append(duplicate)

        XCTAssertThrowsError(try config.canonicalData()) { error in
            XCTAssertEqual(.duplicateIdentifier, error as? ShortcutConfigurationError)
        }
    }

    func testG0WithModifiersRequiresAPrimaryKey() {
        var config = BridgeShortcutConfiguration.defaults
        config.mappings[0].triggerUsage = 0
        config.mappings[0].triggerModifiers = 0x01
        config.mappings[0].triggerIncludesG0 = true

        XCTAssertThrowsError(try config.validated()) { error in
            XCTAssertEqual(.invalidUsage, error as? ShortcutConfigurationError)
        }
    }

    func testShortcutRecorderMapsSpecialFunctionArrowAndKeypadKeys() {
        XCTAssertEqual(0x28, ShortcutRecorderDomain.hidUsage(forMacKeyCode: 36))
        XCTAssertEqual(0x29, ShortcutRecorderDomain.hidUsage(forMacKeyCode: 53))
        XCTAssertEqual(0x2a, ShortcutRecorderDomain.hidUsage(forMacKeyCode: 51))
        XCTAssertEqual(0x3a, ShortcutRecorderDomain.hidUsage(forMacKeyCode: 122))
        XCTAssertEqual(0x50, ShortcutRecorderDomain.hidUsage(forMacKeyCode: 123))
        XCTAssertEqual(0x52, ShortcutRecorderDomain.hidUsage(forMacKeyCode: 126))
        XCTAssertEqual(0x58, ShortcutRecorderDomain.hidUsage(forMacKeyCode: 76))
        XCTAssertNil(ShortcutRecorderDomain.hidUsage(forMacKeyCode: 0xffff))
    }

    func testShortcutRecorderBuildsModifierChordAndReadableLabel() {
        let modifiers = ShortcutRecorderDomain.modifiers(
            control: true,
            shift: true,
            option: false,
            command: true
        )

        XCTAssertEqual(0x0b, modifiers)
        XCTAssertEqual("⌃⇧⌘Return", ShortcutRecorderDomain.displayValue(
            usage: 0x28,
            modifiers: modifiers
        ))
    }

    func testModifierOnlyOutputSupportsDistinctLeftAndRightCommandKeys() throws {
        var config = BridgeShortcutConfiguration.defaults
        config.mappings[0].modifiers = 0x88
        config.mappings[0].outputUsage = 0

        XCTAssertNoThrow(try config.validated())
        XCTAssertEqual("L⌘R⌘", ShortcutRecorderDomain.displayValue(
            usage: 0,
            modifiers: 0x88
        ))
        XCTAssertEqual(0x08, ShortcutRecorderDomain.modifierBit(forMacKeyCode: 55))
        XCTAssertEqual(0x80, ShortcutRecorderDomain.modifierBit(forMacKeyCode: 54))
    }

    func testOutputCannotBeCompletelyEmpty() {
        var config = BridgeShortcutConfiguration.defaults
        config.mappings[0].modifiers = 0
        config.mappings[0].outputUsage = 0

        XCTAssertThrowsError(try config.validated()) { error in
            XCTAssertEqual(.invalidUsage, error as? ShortcutConfigurationError)
        }
    }

    func testCaptureStateRecordsModifierOnlyLeftAndRightCommandAfterRelease() {
        var state = ShortcutCaptureState()
        XCTAssertNil(state.modifierTransition(macKeyCode: 55))
        XCTAssertNil(state.modifierTransition(macKeyCode: 54))
        XCTAssertNil(state.modifierTransition(macKeyCode: 55))
        XCTAssertEqual(
            ShortcutCaptureResult(usage: 0, modifiers: 0x88),
            state.modifierTransition(macKeyCode: 54)
        )
    }

    func testCaptureStateWaitsForFullChordRelease() {
        var state = ShortcutCaptureState()
        XCTAssertNil(state.modifierTransition(macKeyCode: 59))
        XCTAssertNil(state.modifierTransition(macKeyCode: 55))
        state.primaryDown(macKeyCode: 12, usage: 0x14)
        XCTAssertNil(state.primaryUp(macKeyCode: 12))
        XCTAssertNil(state.modifierTransition(macKeyCode: 55))
        XCTAssertEqual(
            ShortcutCaptureResult(usage: 0x14, modifiers: 0x09),
            state.modifierTransition(macKeyCode: 59)
        )
    }

    func testEscapeCancelsDirectRecordingInsteadOfReplacingTheShortcut() {
        XCTAssertTrue(ShortcutRecorderDomain.shouldCancelRecording(forMacKeyCode: 53))
        XCTAssertFalse(ShortcutRecorderDomain.shouldCancelRecording(forMacKeyCode: 12))
    }

    func testCardputerTriggerCatalogMatchesItsPhysicalAndFnLayers() {
        XCTAssertTrue(ShortcutRecorderDomain.isCardputerTrigger(usage: 0x14))
        XCTAssertTrue(ShortcutRecorderDomain.isCardputerTrigger(usage: 0x3a))
        XCTAssertTrue(ShortcutRecorderDomain.isCardputerTrigger(usage: 0x52))
        XCTAssertFalse(ShortcutRecorderDomain.isCardputerTrigger(usage: 0x4a))
        XCTAssertFalse(ShortcutRecorderDomain.isCardputerTrigger(usage: 0x58))
    }
}
