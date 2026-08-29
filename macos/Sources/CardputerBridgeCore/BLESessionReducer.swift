public enum BluetoothRadioState: String, Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

public enum BLESessionPhase: String, Equatable, Sendable {
    case waitingForBluetooth
    case scanning
    case deviceFound
    case connecting
    case discoveringServices
    case authenticating
    case ready
    case blocked
    case failed
}

public struct BLEDevice: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct BLESessionState: Equatable, Sendable {
    public var radio: BluetoothRadioState
    public var phase: BLESessionPhase
    public var device: BLEDevice?
    public var identity: String?
    public var fault: String?

    public var canSendCommand: Bool {
        phase == .ready && identity != nil
    }

    public init(
        radio: BluetoothRadioState = .unknown,
        phase: BLESessionPhase = .waitingForBluetooth,
        device: BLEDevice? = nil,
        identity: String? = nil,
        fault: String? = nil
    ) {
        self.radio = radio
        self.phase = phase
        self.device = device
        self.identity = identity
        self.fault = fault
    }
}

public enum BLESessionEvent: Equatable, Sendable {
    case radioChanged(BluetoothRadioState)
    case deviceDiscovered(id: String, name: String)
    case knownDeviceRediscovered(id: String, name: String)
    case connectRequested
    case connected
    case vendorCharacteristicsReady
    case identityRead(String)
    case servicesInvalidated
    case disconnected(reason: String)
    case failed(reason: String)
    case retryRequested
}

public enum BLESessionEffect: Equatable, Sendable {
    case startScan
    case stopScan
    case connect(deviceID: String)
    case discoverVendorService
    case requestEncryptedIdentityAndSubscribe
}

public struct BLESessionReducer: Sendable {
    public private(set) var state: BLESessionState

    public init(state: BLESessionState = BLESessionState()) {
        self.state = state
    }

    @discardableResult
    public mutating func dispatch(_ event: BLESessionEvent) -> [BLESessionEffect] {
        switch event {
        case .radioChanged(let radio):
            state.radio = radio
            if radio == .poweredOn {
                state.fault = nil
                state.phase = .scanning
                return [.startScan]
            }
            state.device = nil
            state.identity = nil
            switch radio {
            case .unauthorized:
                state.fault = "bluetooth_unauthorized"
                state.phase = .blocked
            case .unsupported:
                state.fault = "bluetooth_unsupported"
                state.phase = .blocked
            case .poweredOff:
                state.fault = "bluetooth_powered_off"
                state.phase = .blocked
            case .unknown, .resetting:
                state.fault = nil
                state.phase = .waitingForBluetooth
            case .poweredOn:
                break
            }
            return []
        case .deviceDiscovered(let id, let name):
            guard state.phase == .scanning else {
                return []
            }
            state.device = BLEDevice(id: id, name: name)
            state.phase = .deviceFound
            return [.stopScan]
        case .knownDeviceRediscovered(let id, let name):
            guard state.phase == .scanning else {
                return []
            }
            state.device = BLEDevice(id: id, name: name)
            state.fault = nil
            state.phase = .connecting
            return [.stopScan, .connect(deviceID: id)]
        case .connectRequested:
            guard state.phase == .deviceFound, let device = state.device else {
                return []
            }
            state.phase = .connecting
            return [.connect(deviceID: device.id)]
        case .connected:
            guard state.phase == .connecting else {
                return []
            }
            state.phase = .discoveringServices
            return [.discoverVendorService]
        case .vendorCharacteristicsReady:
            guard state.phase == .discoveringServices else {
                return []
            }
            state.phase = .authenticating
            return [.requestEncryptedIdentityAndSubscribe]
        case .identityRead(let identity):
            guard state.phase == .authenticating else {
                return []
            }
            state.identity = identity
            state.fault = nil
            state.phase = .ready
            return []
        case .servicesInvalidated:
            guard state.device != nil, state.radio == .poweredOn else {
                return []
            }
            state.identity = nil
            state.fault = nil
            state.phase = .discoveringServices
            return [.discoverVendorService]
        case .disconnected(let reason):
            state.identity = nil
            state.device = nil
            state.fault = reason
            if state.radio == .poweredOn {
                state.phase = .scanning
                return [.startScan]
            }
            state.phase = .waitingForBluetooth
            return []
        case .failed(let reason):
            state.identity = nil
            state.fault = reason
            state.phase = .failed
            return []
        case .retryRequested:
            guard state.phase == .failed, state.radio == .poweredOn else {
                return []
            }
            state.device = nil
            state.identity = nil
            state.fault = nil
            state.phase = .scanning
            return [.startScan]
        }
    }
}
