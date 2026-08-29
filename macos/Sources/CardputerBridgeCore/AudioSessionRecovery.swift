import Foundation

public enum AudioSessionRecovery {
    public static func shouldOfferSession(
        controlIsReady: Bool,
        wifiIsConnected: Bool,
        authenticatedPacketCount: Int
    ) -> Bool {
        // A device-side `audio:ready` flag may describe a session owned by a
        // previous App process. The current process trusts only its own packet
        // authenticator as proof of end-to-end session agreement.
        controlIsReady && wifiIsConnected && authenticatedPacketCount == 0
    }

    public static func shouldRotateSession(
        previousDeviceWasReady: Bool,
        currentDeviceIsReady: Bool,
        wifiIsConnected: Bool
    ) -> Bool {
        previousDeviceWasReady && !currentDeviceIsReady && wifiIsConnected
    }

    public static func shouldRotateStaleAuthenticatedSession(
        deviceAudioIsReady: Bool,
        wifiIsConnected: Bool,
        authenticatedPacketCount: Int
    ) -> Bool {
        !deviceAudioIsReady && wifiIsConnected && authenticatedPacketCount > 0
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
