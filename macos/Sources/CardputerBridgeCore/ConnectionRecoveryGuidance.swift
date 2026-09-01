public enum ConnectionRecoveryKind: Equatable, Sendable {
    case stalePairing
    case firmware
    case general
}

public enum ConnectionRecoveryGuidance {
    public static func classify(fault: String?) -> ConnectionRecoveryKind {
        guard let fault else { return .general }
        if fault.hasPrefix("secure_pairing_failed_") {
            return .stalePairing
        }
        if fault == "vendor_service_missing" ||
            fault == "vendor_characteristics_missing" ||
            fault.hasPrefix("protocol_mismatch") {
            return .firmware
        }
        return .general
    }
}
