import Foundation

public struct CardputerDiagnosticsReport: Codable, Equatable, Sendable {
    public let schemaVersion = 1
    public let generatedAt: Date
    public let appVersion: String
    public let blePhase: String
    public let microphoneIntent: String
    public let audioStatus: String
    public let systemMicrophoneReady: Bool
    public let configurationSynced: Bool
    public let wifiConnected: Bool
    public let batteryPercent: Int?
    public let wifiRSSI: Int?
    public let acceptedPackets: Int
    public let missingPackets: Int
    public let duplicateOrLatePackets: Int
    public let controlFault: String?
    public let audioFault: String?

    public init(
        generatedAt: Date,
        appVersion: String,
        blePhase: String,
        microphoneIntent: String,
        audioStatus: String,
        systemMicrophoneReady: Bool,
        configurationSynced: Bool,
        wifiConnected: Bool,
        batteryPercent: Int?,
        wifiRSSI: Int?,
        acceptedPackets: Int,
        missingPackets: Int,
        duplicateOrLatePackets: Int,
        controlFault: String?,
        audioFault: String?
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.blePhase = blePhase
        self.microphoneIntent = microphoneIntent
        self.audioStatus = audioStatus
        self.systemMicrophoneReady = systemMicrophoneReady
        self.configurationSynced = configurationSynced
        self.wifiConnected = wifiConnected
        self.batteryPercent = batteryPercent
        self.wifiRSSI = wifiRSSI
        self.acceptedPackets = acceptedPackets
        self.missingPackets = missingPackets
        self.duplicateOrLatePackets = duplicateOrLatePackets
        self.controlFault = controlFault
        self.audioFault = audioFault
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case appVersion = "app_version"
        case blePhase = "ble_phase"
        case microphoneIntent = "microphone_intent"
        case audioStatus = "audio_status"
        case systemMicrophoneReady = "system_microphone_ready"
        case configurationSynced = "configuration_synced"
        case wifiConnected = "wifi_connected"
        case batteryPercent = "battery_percent"
        case wifiRSSI = "wifi_rssi"
        case acceptedPackets = "accepted_packets"
        case missingPackets = "missing_packets"
        case duplicateOrLatePackets = "duplicate_or_late_packets"
        case controlFault = "control_fault"
        case audioFault = "audio_fault"
    }
}
