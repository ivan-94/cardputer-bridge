public struct MicrophoneIntentAuthority: Equatable, Sendable {
    public private(set) var desired: RemoteMicIntent
    public private(set) var observed: RemoteMicIntent
    public private(set) var baselineEstablished: Bool
    public private(set) var appCommandPending: Bool

    public init(
        desired: RemoteMicIntent = .muted,
        observed: RemoteMicIntent = .muted
    ) {
        self.desired = desired
        self.observed = observed
        baselineEstablished = false
        appCommandPending = false
    }

    public var heartbeatIntent: RemoteMicIntent {
        desired
    }

    public var isConverged: Bool {
        desired == observed
    }

    public mutating func beginConnectionSession() {
        desired = .muted
        baselineEstablished = false
        appCommandPending = false
    }

    @discardableResult
    public mutating func observeDeviceIntent(
        _ intent: RemoteMicIntent
    ) -> Bool {
        observed = intent
        if !baselineEstablished {
            if intent == .muted {
                baselineEstablished = true
                return false
            }
            return true
        }
        if appCommandPending {
            if intent == desired {
                appCommandPending = false
                return false
            }
            return true
        }

        // With a safe muted baseline and no App command outstanding, the
        // device is the authority for a physical G0 press.
        desired = intent
        return false
    }

    @discardableResult
    public mutating func toggleByUser() -> RemoteMicIntent {
        // If the device has not converged yet, a press should reinforce what
        // the UI offers (for example, "静音"), never invert a stale device
        // report into a new live authorization.
        if !baselineEstablished || appCommandPending || !isConverged {
            return desired
        }
        desired = desired == .muted ? .live : .muted
        appCommandPending = true
        return desired
    }
}
