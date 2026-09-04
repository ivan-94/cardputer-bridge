import Foundation

public enum AudioSessionRecovery {
    // Keep one listener, port and session ID stable while the device resolves ARP and
    // retries UDP proofs. Rotation remains the last-resort recovery
    // for a genuinely stale device session, not the normal retry mechanism.
    public static let failedOfferRotationSeconds: TimeInterval = 15

    // A BLE/Wi-Fi coexistence stall can delay the UDP proof datagrams and the three
    // muted probe frames by more than one second while the association
    // remains healthy. Keep this shorter than the session rotation
    // window so same-session recovery gets the first chance to succeed.
    public static let candidateValidationTimeoutSeconds: TimeInterval = 3

    public static func shouldOfferSession(
        controlIsReady: Bool,
        wifiIsConnected: Bool,
        acceptedPacketCount: Int
    ) -> Bool {
        // A device-side `audio:ready` flag may describe a session owned by a
        // previous App process. The current process trusts only its own packet
        // validator for session agreement; this does not authenticate the sender.
        controlIsReady && wifiIsConnected && acceptedPacketCount == 0
    }

    public static func shouldRotateSession(
        previousDeviceWasReady: Bool,
        currentDeviceIsReady: Bool,
        wifiIsConnected: Bool,
        secondsContinuouslyNotReady: TimeInterval,
        settlementInterval: TimeInterval
    ) -> Bool {
        previousDeviceWasReady &&
            !currentDeviceIsReady &&
            wifiIsConnected &&
            secondsContinuouslyNotReady >= settlementInterval
    }

    public static func shouldRotateFailedOffer(
        currentSessionID: UInt64,
        lastOfferedSessionID: UInt64?,
        elapsedSeconds: TimeInterval,
        retryInterval: TimeInterval
    ) -> Bool {
        currentSessionID == lastOfferedSessionID &&
            elapsedSeconds >= retryInterval
    }
}
