@preconcurrency import CoreBluetooth
import CardputerBridgeCore
import Combine
import Foundation

@MainActor
final class BLEBridgeController: NSObject, ObservableObject {
    @Published private(set) var state = BLESessionState()
    @Published private(set) var deviceStateJSON = ""
    @Published private(set) var micIntent = "muted"
    @Published private(set) var hidConnected = false
    @Published private(set) var deviceConfigVersion: UInt64?
    @Published private(set) var currentWiFiSSID: String?
    @Published private(set) var commandFault: String?
    @Published private(set) var shortcutLearnEvent: ShortcutLearnEvent?
    @Published private(set) var lastShortcutEvent: ShortcutTriggeredEvent?
    @Published private(set) var deviceTelemetry: DeviceTelemetry?
    @Published private(set) var firmwareIdentity: DeviceFirmwareIdentity?
    @Published private(set) var firmwareOTAEvent: FirmwareOTAEvent?

    private var reducer = BLESessionReducer()
    private var central: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]
    private var selectedPeripheral: CBPeripheral?
    private var reconnectDeviceID: String?
    private var rememberedDeviceID: String?
    private var identityCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var stateCharacteristic: CBCharacteristic?
    private var heartbeatCharacteristic: CBCharacteristic?
    private var heartbeatTimer: Timer?
    private var lastHeartbeatSentAt: Date?
    private var heartbeatWriteInFlight = false
    private let heartbeatWriteTimeout: TimeInterval = 2.0
    private var heartbeatWriteTotal = 0
    private var heartbeatWriteAcknowledgedTotal = 0
    private var heartbeatRecoveryTotal = 0
    private var commandWriteQueue: [Data] = []
    private var commandWriteInFlight = false
    private var commandWriteTotal = 0
    private var commandWriteAcknowledgedTotal = 0
    private var commandWriteFailureTotal = 0
    private var audioOfferAttemptTotal = 0
    private var microphoneIntentAuthority = MicrophoneIntentAuthority()
    private let runtimeProbeURL: URL?
    private let startMicrophoneLiveForHarness: Bool
    private let startShortcutLearningForHarness: Bool
    private var harnessMicrophoneIntentSent = false
    private var harnessShortcutLearnToken: UInt32?
    private var managerStarted = false

    private static let rememberedDeviceDefaultsKey =
        "cardputerBridge.rememberedPeripheralID"

    private let bridgeServiceUUID = CBUUID(string: BLEProtocolV1.bridgeServiceUUID)
    private let hidServiceUUID = CBUUID(string: BLEProtocolV1.hidServiceUUID)
    private let identityUUID = CBUUID(string: BLEProtocolV1.identityCharacteristicUUID)
    private let commandUUID = CBUUID(string: BLEProtocolV1.commandCharacteristicUUID)
    private let stateUUID = CBUUID(string: BLEProtocolV1.stateCharacteristicUUID)
    private let heartbeatUUID = CBUUID(
        string: BLEProtocolV1.heartbeatCharacteristicUUID
    )

    override init() {
        runtimeProbeURL = ProcessInfo.processInfo.environment[
            "CARDPUTER_BRIDGE_BLUETOOTH_PROBE_PATH"
        ].map(URL.init(fileURLWithPath:))
        #if DEBUG
        startMicrophoneLiveForHarness = ProcessInfo.processInfo.environment[
            "CARDPUTER_BRIDGE_START_MIC_LIVE"
        ] == "1"
        startShortcutLearningForHarness = ProcessInfo.processInfo.environment[
            "CARDPUTER_BRIDGE_START_SHORTCUT_LEARNING"
        ] == "1"
        #else
        // Production builds never authorize live capture from an environment
        // variable. Only an explicit UI/device action can change the intent.
        startMicrophoneLiveForHarness = false
        startShortcutLearningForHarness = false
        #endif
        super.init()
        rememberedDeviceID = UserDefaults.standard.string(
            forKey: Self.rememberedDeviceDefaultsKey
        )
        publishRuntimeProbe()
    }

    func start() {
        guard central == nil else { return }
        managerStarted = true
        publishRuntimeProbe()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func tickHarnessMicrophone() {
        startHarnessMicrophoneIfReady()
    }

    func tickHarnessShortcutLearning() {
        guard startShortcutLearningForHarness,
              harnessShortcutLearnToken == nil,
              state.canSendCommand else { return }
        harnessShortcutLearnToken = startShortcutLearning()
        publishRuntimeProbe()
    }

    func connect() {
        dispatch(.connectRequested)
    }

    func retry() {
        dispatch(.retryRequested)
    }

    func toggleMicrophoneIntent() {
        guard state.canSendCommand else {
            commandFault = "control_channel_not_ready"
            return
        }
        let targetIntent = microphoneIntentAuthority.toggleByUser()
        enqueueMicrophoneIntent(targetIntent)
    }

    private func enqueueMicrophoneIntent(_ targetIntent: RemoteMicIntent) {
        let message = SetMicIntentMessage(
            id: UUID().uuidString,
            sentAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            intent: targetIntent
        )
        let payload: Data
        do {
            payload = try message.encoded()
        } catch {
            commandFault = "control_message_encode_failed"
            return
        }
        enqueueControlWrites([payload])
    }

    func provisionWiFiAndStartAudio(
        ssid: String,
        password: String,
        offer: AudioOfferMessage
    ) {
        guard state.canSendCommand else {
            commandFault = "control_channel_not_ready"
            return
        }
        do {
            let provisioning = try WiFiProvisioningMessages(
                ssid: ssid,
                password: password
            ).encodedWrites()
            enqueueControlWrites(provisioning + [try offer.encoded()])
        } catch {
            commandFault = "wifi_or_audio_offer_invalid_\(error)"
        }
    }

    func confirmAudioReady(sessionID: UInt64) {
        guard state.canSendCommand else { return }
        do {
            enqueueControlWrites([
                try AudioReadyMessage(sessionID: sessionID).encoded()
            ])
        } catch {
            commandFault = "audio_ready_encode_failed_\(error)"
        }
    }

    func startAudio(offer: AudioOfferMessage) {
        audioOfferAttemptTotal += 1
        publishRuntimeProbe()
        guard state.canSendCommand else { return }
        do {
            enqueueControlWrites([try offer.encoded()])
        } catch {
            commandFault = "audio_offer_invalid_\(error)"
        }
    }

    func syncShortcutConfiguration(_ configuration: BridgeShortcutConfiguration) {
        guard state.canSendCommand else {
            commandFault = "control_channel_not_ready"
            return
        }
        do {
            enqueueControlWrites(try configuration.encodedTransferWrites())
        } catch {
            commandFault = "shortcut_config_encode_failed_\(error)"
        }
    }

    func startShortcutLearning() -> UInt32? {
        guard state.canSendCommand else {
            commandFault = "control_channel_not_ready"
            return nil
        }
        let token = UInt32.random(in: 1...UInt32.max)
        do {
            shortcutLearnEvent = nil
            enqueueControlWrites([
                try ShortcutLearnControlMessage(
                    action: .start,
                    token: token
                ).encoded()
            ])
            return token
        } catch {
            commandFault = "shortcut_learn_start_encode_failed_\(error)"
            return nil
        }
    }

    func cancelShortcutLearning(token: UInt32) {
        guard token != 0, state.canSendCommand else { return }
        do {
            enqueueControlWrites([
                try ShortcutLearnControlMessage(
                    action: .cancel,
                    token: token
                ).encoded()
            ])
        } catch {
            commandFault = "shortcut_learn_cancel_encode_failed_\(error)"
        }
    }

    @discardableResult
    func startFirmwareOTA(release: FirmwareReleasePayload) -> Bool {
        guard state.canSendCommand else {
            commandFault = "control_channel_not_ready"
            return false
        }
        do {
            firmwareOTAEvent = nil
            enqueueControlWrites([
                try FirmwareOTAStartMessage(
                    version: release.version,
                    url: release.firmware.ota.url
                ).encoded()
            ])
            return true
        } catch {
            commandFault = "firmware_ota_command_invalid_\(error)"
            return false
        }
    }

    private func enqueueControlWrites(_ writes: [Data]) {
        guard let selectedPeripheral else {
            commandFault = "control_channel_not_ready"
            return
        }
        let maximum = min(
            160,
            selectedPeripheral.maximumWriteValueLength(for: .withResponse)
        )
        guard writes.allSatisfy({ !$0.isEmpty && $0.count <= maximum }) else {
            commandFault = "control_message_too_large"
            return
        }
        commandFault = nil
        commandWriteQueue.append(contentsOf: writes)
        writeNextControlMessage()
    }

    private func writeNextControlMessage() {
        guard !commandWriteInFlight,
              GATTWriteArbitration.canStartCommand(
                  heartbeatWriteInFlight: heartbeatWriteInFlight
              ),
              !commandWriteQueue.isEmpty,
              let selectedPeripheral,
              let commandCharacteristic else { return }
        commandWriteInFlight = true
        commandWriteTotal += 1
        selectedPeripheral.writeValue(
            commandWriteQueue.removeFirst(),
            for: commandCharacteristic,
            type: .withResponse
        )
    }

    private func startHeartbeatLoop() {
        heartbeatTimer?.invalidate()
        lastHeartbeatSentAt = nil
        heartbeatWriteInFlight = false
        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(heartbeatTimerFired),
            userInfo: nil,
            repeats: true
        )
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sendHeartbeatIfDue(force: true)
    }

    @objc private func heartbeatTimerFired() {
        sendHeartbeatIfDue()
    }

    private func sendHeartbeatIfDue(force: Bool = false) {
        guard state.canSendCommand else { return }
        guard let selectedPeripheral, let heartbeatCharacteristic else { return }
        let now = Date()
        if let lastHeartbeatSentAt,
           HeartbeatWriteWatchdog.shouldReset(
               writeInFlight: heartbeatWriteInFlight,
               elapsedSeconds: now.timeIntervalSince(lastHeartbeatSentAt),
               timeoutSeconds: heartbeatWriteTimeout
           ) {
            rebuildBluetoothSessionAfterHeartbeatFailure(
                reason: "heartbeat_write_timeout",
                peripheral: selectedPeripheral
            )
            return
        }
        guard !heartbeatWriteInFlight else { return }
        guard GATTWriteArbitration.canStartHeartbeat(
            commandWriteInFlight: commandWriteInFlight,
            commandQueueDepth: commandWriteQueue.count
        ) else { return }
        let interval = micIntent == "live" ||
            microphoneIntentAuthority.desired == .live ? 0.1 : 1.0
        if !force,
           let lastHeartbeatSentAt,
           now.timeIntervalSince(lastHeartbeatSentAt) < interval {
            return
        }
        let intent = microphoneIntentAuthority.heartbeatIntent
        let message = HeartbeatMessage(
            id: UUID().uuidString,
            sentAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            intent: intent
        )
        guard let payload = try? message.encoded(), payload.count <= 160 else {
            commandFault = "heartbeat_encode_failed"
            return
        }
        heartbeatWriteInFlight = true
        heartbeatWriteTotal += 1
        selectedPeripheral.writeValue(
            payload,
            for: heartbeatCharacteristic,
            type: .withResponse
        )
        lastHeartbeatSentAt = now
        publishRuntimeProbe()
    }

    private func rebuildBluetoothSessionAfterHeartbeatFailure(
        reason: String,
        peripheral: CBPeripheral
    ) {
        guard let expiredCentral = central else { return }
        commandFault = reason
        heartbeatRecoveryTotal += 1
        reconnectDeviceID = peripheral.identifier.uuidString

        // A device reset can leave CoreBluetooth without either a write or a
        // disconnect callback. Do not wait forever on that stale manager:
        // discard only the runtime session (the system bond remains intact),
        // then let a fresh manager rediscover and reconnect the known device.
        expiredCentral.stopScan()
        expiredCentral.cancelPeripheralConnection(peripheral)
        expiredCentral.delegate = nil
        clearConnectionHandles()
        peripherals.removeAll()
        central = nil
        reducer = BLESessionReducer()
        state = reducer.state
        managerStarted = false
        publishRuntimeProbe()

        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    private func dispatch(_ event: BLESessionEvent) {
        let effects = reducer.dispatch(event)
        state = reducer.state
        publishRuntimeProbe()
        for effect in effects {
            perform(effect)
        }
        startHarnessMicrophoneIfReady()
    }

    private func perform(_ effect: BLESessionEffect) {
        switch effect {
        case .startScan:
            guard central?.state == .poweredOn else { return }
            let knownDeviceID = reconnectDeviceID ?? rememberedDeviceID
            if let knownDeviceID,
               let uuid = UUID(uuidString: knownDeviceID),
               let known = central?.retrievePeripherals(
                   withIdentifiers: [uuid]
               ).first {
                peripherals[knownDeviceID] = known
                reconnectDeviceID = nil
                dispatch(
                    .knownDeviceRediscovered(
                        id: knownDeviceID,
                        name: known.name ?? BLEProtocolV1.deviceName
                    )
                )
                return
            }
            central?.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .stopScan:
            central?.stopScan()
        case .connect(let deviceID):
            guard let peripheral = peripherals[deviceID] else {
                dispatch(.failed(reason: "discovered_device_expired"))
                return
            }
            selectedPeripheral = peripheral
            central?.connect(peripheral)
        case .discoverVendorService:
            selectedPeripheral?.discoverServices([bridgeServiceUUID])
        case .requestEncryptedIdentityAndSubscribe:
            guard let selectedPeripheral,
                  let identityCharacteristic,
                  let stateCharacteristic else {
                dispatch(.failed(reason: "vendor_characteristics_missing"))
                return
            }
            // Both operations require encrypted + MITM access on the device.
            // macOS owns the system pairing UI; a successful identity read is
            // therefore the observable authorization boundary for the App.
            selectedPeripheral.setNotifyValue(true, for: stateCharacteristic)
            selectedPeripheral.readValue(for: identityCharacteristic)
            selectedPeripheral.readValue(for: stateCharacteristic)
        }
    }

    private func clearConnectionHandles() {
        selectedPeripheral?.delegate = nil
        selectedPeripheral = nil
        identityCharacteristic = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        heartbeatCharacteristic = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lastHeartbeatSentAt = nil
        heartbeatWriteInFlight = false
        commandWriteQueue.removeAll()
        commandWriteInFlight = false
        deviceStateJSON = ""
        shortcutLearnEvent = nil
        lastShortcutEvent = nil
        deviceTelemetry = nil
        firmwareIdentity = nil
        firmwareOTAEvent = nil
        micIntent = "muted"
        hidConnected = false
        deviceConfigVersion = nil
        currentWiFiSSID = nil
        microphoneIntentAuthority.beginConnectionSession()
    }

    private func recordStateValue(_ data: Data) {
        if let event = FirmwareOTAEvent.decode(from: data) {
            firmwareOTAEvent = event
            publishRuntimeProbe()
            return
        }
        if let event = ShortcutLearnEvent.decode(from: data) {
            shortcutLearnEvent = event
            publishRuntimeProbe()
            return
        }
        if let event = ShortcutTriggeredEvent.decode(from: data) {
            lastShortcutEvent = event
            publishRuntimeProbe()
            return
        }
        if let telemetry = DeviceTelemetry.decode(from: data) {
            deviceTelemetry = telemetry
            publishRuntimeProbe()
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            commandFault = "state_payload_not_utf8"
            return
        }
        deviceStateJSON = text
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let encodedIntent = object["mic_intent"] as? String,
           let intent = RemoteMicIntent(rawValue: encodedIntent) {
            let intentChanged = micIntent != encodedIntent
            let needsCorrection = microphoneIntentAuthority.observeDeviceIntent(intent)
            micIntent = encodedIntent
            if intentChanged || needsCorrection {
                sendHeartbeatIfDue(force: true)
            }
            startHarnessMicrophoneIfReady(audioIsReady: object["audio"] as? String == "ready")
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ssid = (object["ssid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            currentWiFiSSID = (ssid?.isEmpty == false) ? ssid : nil
            hidConnected = object["hid"] as? String == "connected"
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let encodedVersion = object["cfg_v"] as? String {
            deviceConfigVersion = UInt64(encodedVersion, radix: 16)
        }
        publishRuntimeProbe()
    }

    private func startHarnessMicrophoneIfReady(audioIsReady: Bool? = nil) {
        guard startMicrophoneLiveForHarness,
              !harnessMicrophoneIntentSent,
              state.canSendCommand else { return }
        let ready = audioIsReady ?? (
            (try? JSONSerialization.jsonObject(
                with: Data(deviceStateJSON.utf8)
            ) as? [String: Any])?["audio"] as? String == "ready"
        )
        guard ready else { return }
        harnessMicrophoneIntentSent = true
        if microphoneIntentAuthority.desired == .muted {
            toggleMicrophoneIntent()
        }
    }

    private func authorizationFailure(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == CBATTErrorDomain {
            return "secure_pairing_failed_\(nsError.code)"
        }
        return "gatt_error_\(nsError.code)"
    }

    private func publishRuntimeProbe() {
        guard let runtimeProbeURL else { return }
        let learnEvent: Any = shortcutLearnEvent.map { event in
            [
                "event": event.event.rawValue,
                "token": event.token,
                "g0": event.includesG0 ?? NSNull(),
                "mods": event.modifiers ?? NSNull(),
                "usage": event.usage ?? NSNull(),
            ] as [String: Any]
        } ?? NSNull()
        let shortcutEvent: Any = lastShortcutEvent.map { event in
            [
                "g0": event.includesG0,
                "trigger_modifiers": event.triggerModifiers,
                "trigger_usage": event.triggerUsage,
                "output_modifiers": event.outputModifiers,
                "output_usage": event.outputUsage,
            ] as [String: Any]
        } ?? NSNull()
        let snapshot: [String: Any] = [
            "v": 1,
            "radio": reducer.state.radio.rawValue,
            "phase": reducer.state.phase.rawValue,
            "manager_started": managerStarted,
            "fault": reducer.state.fault ?? NSNull(),
            "command_fault": commandFault ?? NSNull(),
            "remembered_device_id": rememberedDeviceID ?? NSNull(),
            "reconnect_device_id": reconnectDeviceID ?? NSNull(),
            "heartbeat_write_in_flight": heartbeatWriteInFlight,
            "heartbeat_write_total": heartbeatWriteTotal,
            "heartbeat_write_acknowledged_total": heartbeatWriteAcknowledgedTotal,
            "heartbeat_recovery_total": heartbeatRecoveryTotal,
            "device_state": deviceStateJSON,
            "hid_connected": hidConnected,
            "desired_mic_intent": microphoneIntentAuthority.desired.rawValue,
            "audio_offer_attempt_total": audioOfferAttemptTotal,
            "device_config_version": deviceConfigVersion.map(String.init) ?? NSNull(),
            "command_write_in_flight": commandWriteInFlight,
            "command_write_queue_depth": commandWriteQueue.count,
            "command_write_total": commandWriteTotal,
            "command_write_acknowledged_total": commandWriteAcknowledgedTotal,
            "command_write_failure_total": commandWriteFailureTotal,
            "shortcut_learn_harness_enabled": startShortcutLearningForHarness,
            "shortcut_learn_harness_token": harnessShortcutLearnToken.map(String.init) ?? NSNull(),
            "shortcut_learn_event": learnEvent,
            "last_shortcut_event": shortcutEvent,
            "battery_percent": deviceTelemetry?.batteryPercent ?? NSNull(),
            "wifi_rssi": deviceTelemetry?.wifiRSSI ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.sortedKeys]
        ) else { return }
        try? data.write(to: runtimeProbeURL, options: .atomic)
    }
}

extension BLEBridgeController: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let radio: BluetoothRadioState = switch central.state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }
        if radio != .poweredOn {
            reconnectDeviceID = nil
            clearConnectionHandles()
        }
        dispatch(.radioChanged(radio))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name
        guard name == BLEProtocolV1.deviceName else { return }

        let id = peripheral.identifier.uuidString
        peripherals[id] = peripheral
        let reconnectsKnownDevice = reconnectDeviceID == id ||
            rememberedDeviceID == id
        if reconnectsKnownDevice {
            reconnectDeviceID = nil
            dispatch(
                .knownDeviceRediscovered(
                    id: id,
                    name: name ?? BLEProtocolV1.deviceName
                )
            )
        } else {
            dispatch(.deviceDiscovered(id: id, name: name ?? BLEProtocolV1.deviceName))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectDeviceID = nil
        peripheral.delegate = self
        dispatch(.connected)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        clearConnectionHandles()
        dispatch(.failed(reason: error?.localizedDescription ?? "ble_connect_failed"))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        if state.device?.id == peripheral.identifier.uuidString {
            reconnectDeviceID = peripheral.identifier.uuidString
        }
        clearConnectionHandles()
        dispatch(.disconnected(reason: error?.localizedDescription ?? "device_disconnected"))
    }
}

extension BLEBridgeController: @preconcurrency CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        guard invalidatedServices.contains(where: { $0.uuid == bridgeServiceUUID }) else {
            return
        }
        identityCharacteristic = nil
        commandCharacteristic = nil
        stateCharacteristic = nil
        heartbeatCharacteristic = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lastHeartbeatSentAt = nil
        heartbeatWriteInFlight = false
        dispatch(.servicesInvalidated)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            dispatch(.failed(reason: authorizationFailure(error)))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == bridgeServiceUUID }) else {
            dispatch(.failed(reason: "vendor_service_missing"))
            return
        }
        peripheral.discoverCharacteristics(
            [identityUUID, commandUUID, stateUUID, heartbeatUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            dispatch(.failed(reason: authorizationFailure(error)))
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case identityUUID: identityCharacteristic = characteristic
            case commandUUID: commandCharacteristic = characteristic
            case stateUUID: stateCharacteristic = characteristic
            case heartbeatUUID: heartbeatCharacteristic = characteristic
            default: break
            }
        }
        guard identityCharacteristic != nil,
              commandCharacteristic != nil,
              stateCharacteristic != nil,
              heartbeatCharacteristic != nil else {
            dispatch(.failed(reason: "vendor_characteristics_missing"))
            return
        }
        dispatch(.vendorCharacteristicsReady)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            dispatch(.failed(reason: authorizationFailure(error)))
            return
        }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == identityUUID {
            firmwareIdentity = DeviceFirmwareIdentity.decode(from: value)
            let identity: String
            if let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any],
               let device = object["device"] as? String {
                identity = device
            } else {
                identity = String(data: value, encoding: .utf8) ?? "Cardputer-ADV"
            }
            dispatch(.identityRead(identity))
            if state.canSendCommand {
                let deviceID = peripheral.identifier.uuidString
                rememberedDeviceID = deviceID
                UserDefaults.standard.set(
                    deviceID,
                    forKey: Self.rememberedDeviceDefaultsKey
                )
                // CoreBluetooth may preserve the physical BLE connection when
                // an App process exits. The state characteristic can then be
                // cached as a telemetry/event payload, so a fresh process sees
                // no HID/Wi-Fi/audio snapshot. Reassert this connection
                // session's safe intent once: the idempotent device command
                // also makes firmware publish a complete current snapshot.
                enqueueMicrophoneIntent(microphoneIntentAuthority.heartbeatIntent)
                startHeartbeatLoop()
                publishRuntimeProbe()
            }
        } else if characteristic.uuid == stateUUID {
            recordStateValue(value)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            dispatch(.failed(reason: authorizationFailure(error)))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if characteristic.uuid == commandUUID {
            commandWriteInFlight = false
            if let error {
                commandWriteQueue.removeAll()
                commandWriteFailureTotal += 1
                commandFault = authorizationFailure(error)
            } else {
                commandWriteAcknowledgedTotal += 1
                commandFault = nil
                writeNextControlMessage()
            }
            publishRuntimeProbe()
            return
        }
        if characteristic.uuid == heartbeatUUID {
            heartbeatWriteInFlight = false
            if let error {
                rebuildBluetoothSessionAfterHeartbeatFailure(
                    reason: authorizationFailure(error),
                    peripheral: peripheral
                )
                return
            }
            heartbeatWriteAcknowledgedTotal += 1
            commandFault = nil
            writeNextControlMessage()
            publishRuntimeProbe()
            return
        }
        commandFault = error.map(authorizationFailure)
    }
}
