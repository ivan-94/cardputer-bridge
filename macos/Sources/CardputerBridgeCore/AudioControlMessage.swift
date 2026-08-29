import CryptoKit
import Foundation

public enum CompactControlMessageError: Error, Equatable {
    case invalidWiFiCredentials
    case messageTooLarge
}

public struct AudioOfferMessage: Sendable {
    public let ipv4: String
    public let port: UInt16
    public let sessionID: UInt64
    public let keyData: Data

    public init(
        ipv4: String,
        port: UInt16,
        sessionID: UInt64,
        key: SymmetricKey
    ) {
        self.ipv4 = ipv4
        self.port = port
        self.sessionID = sessionID
        self.keyData = key.withUnsafeBytes { Data($0) }
    }

    public func encoded() throws -> Data {
        try boundedJSON(AudioOfferWire(
            v: 1,
            type: "audio_offer",
            ip: ipv4,
            port: port,
            sid: String(format: "%016llx", sessionID),
            key: keyData.base64EncodedString()
        ))
    }
}

public struct WiFiProvisioningMessages: Sendable {
    public let ssid: String
    public let password: String

    public init(ssid: String, password: String) {
        self.ssid = ssid
        self.password = password
    }

    public func encodedWrites() throws -> [Data] {
        let ssidData = Data(ssid.utf8)
        let passwordData = Data(password.utf8)
        guard !ssidData.isEmpty,
              ssidData.count <= 32,
              passwordData.count >= 8,
              passwordData.count <= 63 else {
            throw CompactControlMessageError.invalidWiFiCredentials
        }
        return try [
            boundedJSON(StagedValueWire(
                v: 1,
                type: "wifi_stage_ssid",
                value: ssidData.base64EncodedString()
            )),
            boundedJSON(StagedValueWire(
                v: 1,
                type: "wifi_stage_password",
                value: passwordData.base64EncodedString()
            )),
            boundedJSON(CommandWire(v: 1, type: "wifi_commit")),
        ]
    }
}

public struct AudioReadyMessage: Sendable {
    public let sessionID: UInt64

    public init(sessionID: UInt64) {
        self.sessionID = sessionID
    }

    public func encoded() throws -> Data {
        try boundedJSON(CommandWithSessionWire(
            v: 1,
            type: "audio_ready",
            sid: String(format: "%016llx", sessionID)
        ))
    }
}

private let compactControlMessageMaximumBytes = 160

private func boundedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    // The firmware deliberately accepts only unescaped compact control
    // strings. Base64 session keys can contain '/', which JSONEncoder escapes
    // unless this wire-format option is explicit.
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= compactControlMessageMaximumBytes else {
        throw CompactControlMessageError.messageTooLarge
    }
    return data
}

private struct AudioOfferWire: Encodable {
    let v: Int
    let type: String
    let ip: String
    let port: UInt16
    let sid: String
    let key: String
}

private struct StagedValueWire: Encodable {
    let v: Int
    let type: String
    let value: String
}

private struct CommandWire: Encodable {
    let v: Int
    let type: String
}

private struct CommandWithSessionWire: Encodable {
    let v: Int
    let type: String
    let sid: String
}
