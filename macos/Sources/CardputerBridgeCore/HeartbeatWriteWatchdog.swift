import Foundation

public enum HeartbeatWriteWatchdog {
    public static func shouldReset(
        writeInFlight: Bool,
        elapsedSeconds: TimeInterval,
        timeoutSeconds: TimeInterval
    ) -> Bool {
        guard writeInFlight, timeoutSeconds > 0 else { return false }
        return elapsedSeconds >= timeoutSeconds
    }
}
