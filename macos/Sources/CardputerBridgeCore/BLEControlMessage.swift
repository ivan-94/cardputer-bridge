import Foundation

public enum RemoteMicIntent: String, Codable, Sendable {
    case muted
    case live
}

public struct SetMicIntentMessage: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public let intent: RemoteMicIntent
    }

    public let v = 1
    public let id: String
    public let type = "set_mic_intent"
    public let sentAtMilliseconds: Int64
    public let body: Body

    public init(
        id: String,
        sentAtMilliseconds: Int64,
        intent: RemoteMicIntent
    ) {
        self.id = id
        self.sentAtMilliseconds = sentAtMilliseconds
        self.body = Body(intent: intent)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case id
        case type
        case sentAtMilliseconds = "sent_at_ms"
        case body
    }
}

public struct HeartbeatMessage: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public let intent: RemoteMicIntent
    }

    public let v = 1
    public let id: String
    public let type = "heartbeat"
    public let sentAtMilliseconds: Int64
    public let body: Body

    public init(
        id: String,
        sentAtMilliseconds: Int64,
        intent: RemoteMicIntent
    ) {
        self.id = id
        self.sentAtMilliseconds = sentAtMilliseconds
        self.body = Body(intent: intent)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case id
        case type
        case sentAtMilliseconds = "sent_at_ms"
        case body
    }
}

public enum ShortcutLearnAction: String, Codable, Sendable {
    case start = "shortcut_learn_start"
    case cancel = "shortcut_learn_cancel"
}

public struct ShortcutLearnControlMessage: Codable, Equatable, Sendable {
    public let v = 1
    public let type: ShortcutLearnAction
    public let token: UInt32

    public init(action: ShortcutLearnAction, token: UInt32) {
        self.type = action
        self.token = token
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case type
        case token
    }
}

public enum ShortcutLearnEventKind: String, Codable, Sendable {
    case waiting = "shortcut_learning"
    case captured = "shortcut_learned"
    case cancelled = "shortcut_learn_cancelled"
}

public struct ShortcutLearnEvent: Codable, Equatable, Sendable {
    public let v: Int
    public let event: ShortcutLearnEventKind
    public let token: UInt32
    public let includesG0: Bool?
    public let modifiers: UInt8?
    public let usage: UInt8?

    public static func decode(from data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case event
        case token
        case includesG0 = "g0"
        case modifiers = "mods"
        case usage
    }
}

public struct ShortcutTriggeredEvent: Codable, Equatable, Sendable {
    public let v: Int
    public let event: String
    public let includesG0: Bool
    public let triggerModifiers: UInt8
    public let triggerUsage: UInt8
    public let outputModifiers: UInt8
    public let outputUsage: UInt8

    public static func decode(from data: Data) -> Self? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.v == 1,
              value.event == "shortcut_triggered" else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case event
        case includesG0 = "g0"
        case triggerModifiers = "tmods"
        case triggerUsage = "tusage"
        case outputModifiers = "omods"
        case outputUsage = "ousage"
    }
}

public struct DeviceTelemetry: Codable, Equatable, Sendable {
    public let v: Int
    public let event: String
    public let batteryPercent: Int
    public let wifiRSSI: Int
    public let externalPower: Bool
    public let streamFramesSent: UInt32
    public let streamFailures: UInt32
    public let lastStreamError: Int
    public let captureOverruns: UInt32
    public let microphoneRecordFailures: UInt32
    public let captureRingDrops: UInt32
    public let captureRingHighWater: UInt32
    public let maximumCaptureGapMilliseconds: UInt32
    public let maximumTransportGapMilliseconds: UInt32
    public let wifiDisconnectCount: UInt32
    public let lastWiFiDisconnectReason: Int

    public init(
        v: Int = 1,
        event: String = "telemetry",
        batteryPercent: Int,
        wifiRSSI: Int,
        externalPower: Bool = false,
        streamFramesSent: UInt32 = 0,
        streamFailures: UInt32 = 0,
        lastStreamError: Int = 0,
        captureOverruns: UInt32 = 0,
        microphoneRecordFailures: UInt32 = 0,
        captureRingDrops: UInt32 = 0,
        captureRingHighWater: UInt32 = 0,
        maximumCaptureGapMilliseconds: UInt32 = 0,
        maximumTransportGapMilliseconds: UInt32 = 0,
        wifiDisconnectCount: UInt32 = 0,
        lastWiFiDisconnectReason: Int = 0
    ) {
        self.v = v
        self.event = event
        self.batteryPercent = batteryPercent
        self.wifiRSSI = wifiRSSI
        self.externalPower = externalPower
        self.streamFramesSent = streamFramesSent
        self.streamFailures = streamFailures
        self.lastStreamError = lastStreamError
        self.captureOverruns = captureOverruns
        self.microphoneRecordFailures = microphoneRecordFailures
        self.captureRingDrops = captureRingDrops
        self.captureRingHighWater = captureRingHighWater
        self.maximumCaptureGapMilliseconds = maximumCaptureGapMilliseconds
        self.maximumTransportGapMilliseconds = maximumTransportGapMilliseconds
        self.wifiDisconnectCount = wifiDisconnectCount
        self.lastWiFiDisconnectReason = lastWiFiDisconnectReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        event = try container.decode(String.self, forKey: .event)
        batteryPercent = try container.decode(Int.self, forKey: .batteryPercent)
        wifiRSSI = try container.decode(Int.self, forKey: .wifiRSSI)
        externalPower = try container.decodeIfPresent(
            Bool.self,
            forKey: .externalPower
        ) ?? false
        streamFramesSent = try container.decodeIfPresent(
            UInt32.self,
            forKey: .streamFramesSent
        ) ?? 0
        streamFailures = try container.decodeIfPresent(
            UInt32.self,
            forKey: .streamFailures
        ) ?? 0
        lastStreamError = try container.decodeIfPresent(
            Int.self,
            forKey: .lastStreamError
        ) ?? 0
        microphoneRecordFailures = try container.decodeIfPresent(
            UInt32.self,
            forKey: .microphoneRecordFailures
        ) ?? 0
        captureRingDrops = try container.decodeIfPresent(
            UInt32.self,
            forKey: .captureRingDrops
        ) ?? 0
        captureRingHighWater = try container.decodeIfPresent(
            UInt32.self,
            forKey: .captureRingHighWater
        ) ?? 0
        maximumCaptureGapMilliseconds = try container.decodeIfPresent(
            UInt32.self,
            forKey: .maximumCaptureGapMilliseconds
        ) ?? 0
        maximumTransportGapMilliseconds = try container.decodeIfPresent(
            UInt32.self,
            forKey: .maximumTransportGapMilliseconds
        ) ?? 0
        captureOverruns = try container.decodeIfPresent(
            UInt32.self,
            forKey: .captureOverruns
        ) ?? (microphoneRecordFailures &+ captureRingDrops)
        wifiDisconnectCount = try container.decodeIfPresent(
            UInt32.self,
            forKey: .wifiDisconnectCount
        ) ?? 0
        lastWiFiDisconnectReason = try container.decodeIfPresent(
            Int.self,
            forKey: .lastWiFiDisconnectReason
        ) ?? 0
    }

    public static func decode(from data: Data) -> Self? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.v == 1,
              value.event == "telemetry",
              (-1...100).contains(value.batteryPercent),
              (-127...0).contains(value.wifiRSSI) else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case event
        case batteryPercent = "bat"
        case wifiRSSI = "rssi"
        case externalPower = "ext"
        case streamFramesSent = "sent"
        case streamFailures = "fail"
        case lastStreamError = "serr"
        case captureOverruns = "overrun"
        case microphoneRecordFailures = "mf"
        case captureRingDrops = "rd"
        case captureRingHighWater = "rh"
        case maximumCaptureGapMilliseconds = "cg"
        case maximumTransportGapMilliseconds = "tg"
        case wifiDisconnectCount = "wd"
        case lastWiFiDisconnectReason = "wr"
    }
}
