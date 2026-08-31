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

    public init(
        v: Int = 1,
        event: String = "telemetry",
        batteryPercent: Int,
        wifiRSSI: Int,
        externalPower: Bool = false
    ) {
        self.v = v
        self.event = event
        self.batteryPercent = batteryPercent
        self.wifiRSSI = wifiRSSI
        self.externalPower = externalPower
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
    }
}
