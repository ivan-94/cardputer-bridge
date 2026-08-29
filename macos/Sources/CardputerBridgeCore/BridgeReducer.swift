public enum MicIntent: String, Codable, Sendable {
    case muted
    case live
}

public enum CaptureGate: String, Codable, Sendable {
    case closed
    case open
}

public enum BridgeAction: String, Codable, Sendable {
    case toggleMicIntent
    case controlLinkLost
}

public enum ActionSource: String, Codable, Sendable {
    case harness
    case bleControl
    case swiftUI
}

public struct BridgeState: Codable, Equatable, Sendable {
    public var bleAuthorized: Bool
    public var wifiAuthorized: Bool
    public var virtualMicReady: Bool
    public var micIntent: MicIntent
    public var captureGate: CaptureGate

    public static let pairedNoWiFi = BridgeState(
        bleAuthorized: true,
        wifiAuthorized: false,
        virtualMicReady: true,
        micIntent: .muted,
        captureGate: .closed
    )

    public static let readyMuted = BridgeState(
        bleAuthorized: true,
        wifiAuthorized: true,
        virtualMicReady: true,
        micIntent: .muted,
        captureGate: .closed
    )
}

public struct BridgeEvent: Codable, Equatable, Sendable {
    public let eventSequence: UInt64
    public let action: BridgeAction
    public let source: ActionSource
    public let state: BridgeState
}

public struct BridgeReducer: Sendable {
    public private(set) var state: BridgeState
    private var eventSequence: UInt64 = 0

    public init(state: BridgeState = .pairedNoWiFi) {
        self.state = state
        enforceCaptureGate()
    }

    public mutating func reset(to state: BridgeState) {
        self.state = state
        eventSequence = 0
        enforceCaptureGate()
    }

    @discardableResult
    public mutating func dispatch(
        _ action: BridgeAction,
        source: ActionSource
    ) -> BridgeEvent {
        switch action {
        case .toggleMicIntent:
            state.micIntent = state.micIntent == .muted ? .live : .muted
        case .controlLinkLost:
            state.bleAuthorized = false
            state.micIntent = .muted
        }

        enforceCaptureGate()
        eventSequence += 1
        return BridgeEvent(
            eventSequence: eventSequence,
            action: action,
            source: source,
            state: state
        )
    }

    private mutating func enforceCaptureGate() {
        let allAuthoritiesReady = state.bleAuthorized
            && state.wifiAuthorized
            && state.virtualMicReady
        state.captureGate = state.micIntent == .live && allAuthoritiesReady
            ? .open
            : .closed
    }
}
