public enum GATTWriteArbitration {
    public static func canStartHeartbeat(
        commandWriteInFlight: Bool,
        commandQueueDepth: Int
    ) -> Bool {
        !commandWriteInFlight && commandQueueDepth == 0
    }

    public static func canStartCommand(heartbeatWriteInFlight: Bool) -> Bool {
        !heartbeatWriteInFlight
    }
}
