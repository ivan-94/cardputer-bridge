import CryptoKit
import Foundation

public struct DeviceFirmwareIdentity: Codable, Equatable, Sendable {
    public let device: String
    public let firmwareVersion: String?
    public let layoutVersion: Int
    public let otaCapable: Bool

    public init(
        device: String,
        firmwareVersion: String?,
        layoutVersion: Int,
        otaCapable: Bool
    ) {
        self.device = device
        self.firmwareVersion = firmwareVersion
        self.layoutVersion = layoutVersion
        self.otaCapable = otaCapable
    }

    private enum CodingKeys: String, CodingKey {
        case device
        case firmwareVersion = "fw"
        case layoutVersion = "layout"
        case otaCapable = "ota"
    }

    public static func decode(from data: Data) -> DeviceFirmwareIdentity? {
        try? JSONDecoder().decode(DeviceFirmwareIdentity.self, from: data)
    }

    public var status: FirmwareDeviceStatus {
        FirmwareDeviceStatus(
            version: firmwareVersion,
            layoutVersion: layoutVersion,
            otaCapable: otaCapable
        )
    }
}

public struct FirmwareOTAEvent: Codable, Equatable, Sendable {
    public let phase: String
    public let progress: Int
    public let error: Int

    public static func decode(from data: Data) -> FirmwareOTAEvent? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.event == "ota" else { return nil }
        return FirmwareOTAEvent(
            phase: envelope.phase,
            progress: envelope.progress ?? 0,
            error: envelope.error ?? 0
        )
    }

    private struct Envelope: Decodable {
        let event: String
        let phase: String
        let progress: Int?
        let error: Int?
    }
}

public struct FirmwareDeviceStatus: Equatable, Sendable {
    public let version: String?
    public let layoutVersion: Int
    public let otaCapable: Bool

    public init(version: String?, layoutVersion: Int, otaCapable: Bool) {
        self.version = version
        self.layoutVersion = layoutVersion
        self.otaCapable = otaCapable
    }
}

public struct FirmwareReleasePayload: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public let role: String
        public let url: String
        public let bytes: Int
        public let sha256: String
        public let offset: String?

        public init(
            role: String,
            url: String,
            bytes: Int,
            sha256: String,
            offset: String?
        ) {
            self.role = role
            self.url = url
            self.bytes = bytes
            self.sha256 = sha256
            self.offset = offset
        }
    }

    public struct Firmware: Codable, Equatable, Sendable {
        public let chip: String
        public let layoutVersion: Int
        public let ota: Artifact
        public let usb: [Artifact]

        public init(
            chip: String,
            layoutVersion: Int,
            ota: Artifact,
            usb: [Artifact]
        ) {
            self.chip = chip
            self.layoutVersion = layoutVersion
            self.ota = ota
            self.usb = usb
        }

        private enum CodingKeys: String, CodingKey {
            case chip
            case layoutVersion = "layout_version"
            case ota
            case usb
        }
    }

    public let schemaVersion: Int
    public let product: String
    public let channel: String
    public let version: String
    public let minimumMacOSAppVersion: String
    public let publishedAt: String
    public let firmware: Firmware

    public init(
        schemaVersion: Int,
        product: String,
        channel: String,
        version: String,
        minimumMacOSAppVersion: String,
        publishedAt: String,
        firmware: Firmware
    ) {
        self.schemaVersion = schemaVersion
        self.product = product
        self.channel = channel
        self.version = version
        self.minimumMacOSAppVersion = minimumMacOSAppVersion
        self.publishedAt = publishedAt
        self.firmware = firmware
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case product
        case channel
        case version
        case minimumMacOSAppVersion = "minimum_macos_app_version"
        case publishedAt = "published_at"
        case firmware
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct SignedFirmwareRelease: Codable, Equatable, Sendable {
    public struct Signature: Codable, Equatable, Sendable {
        public let algorithm: String
        public let keyID: String
        public let value: String

        public init(algorithm: String, keyID: String, value: String) {
            self.algorithm = algorithm
            self.keyID = keyID
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case algorithm
            case keyID = "key_id"
            case value
        }
    }

    public let payload: FirmwareReleasePayload
    public let signature: Signature

    public init(payload: FirmwareReleasePayload, signature: Signature) {
        self.payload = payload
        self.signature = signature
    }

    public func verify(trustedKeys: [String: Data]) throws {
        guard signature.algorithm == "ed25519" else {
            throw FirmwareReleaseVerificationError.unsupportedAlgorithm
        }
        guard let publicKeyData = trustedKeys[signature.keyID] else {
            throw FirmwareReleaseVerificationError.untrustedKey
        }
        guard let signatureData = Data(base64Encoded: signature.value) else {
            throw FirmwareReleaseVerificationError.invalidSignatureEncoding
        }
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyData
        )
        guard publicKey.isValidSignature(
            signatureData,
            for: try payload.canonicalData()
        ) else {
            throw FirmwareReleaseVerificationError.invalidSignature
        }
        try payload.validateTrustBoundary()
    }
}

public extension FirmwareReleasePayload {
    func validateTrustBoundary() throws {
        guard schemaVersion == 2,
              product == "cardputer-bridge",
              channel == "stable",
              firmware.chip == "esp32s3",
              firmware.layoutVersion >= 2,
              firmware.usb.count == 4 else {
            throw FirmwareReleaseVerificationError.invalidPayload
        }
        let artifacts = [firmware.ota] + firmware.usb
        for artifact in artifacts {
            guard artifact.bytes > 0,
                  artifact.sha256.range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                  ) != nil,
                  let url = URL(string: artifact.url),
                  url.scheme == "https",
                  url.host == "github.com",
                  url.path.hasPrefix("/ivan-94/cardputer-bridge/releases/") else {
                throw FirmwareReleaseVerificationError.invalidPayload
            }
        }
        let expectedUSB: [String: String] = [
            "factory": "0x10000",
            "otadata": "0x610000",
            "partition_table": "0x8000",
            "bootloader": "0x0",
        ]
        guard Dictionary(
            uniqueKeysWithValues: firmware.usb.map { ($0.role, $0.offset ?? "") }
        ) == expectedUSB else {
            throw FirmwareReleaseVerificationError.invalidPayload
        }
    }
}

public enum FirmwareReleaseVerificationError: Error, Equatable {
    case unsupportedAlgorithm
    case untrustedKey
    case invalidSignatureEncoding
    case invalidSignature
    case invalidPayload
}

public struct FirmwareOTAStartMessage: Sendable {
    public let version: String
    public let url: String

    public init(version: String, url: String) {
        self.version = version
        self.url = url
    }

    public func encoded() throws -> Data {
        guard FirmwareVersion(version) != nil else {
            throw FirmwareOTAStartMessageError.invalidVersion
        }
        guard let parsedURL = URL(string: url),
              parsedURL.scheme == "https",
              parsedURL.host == "github.com",
              parsedURL.path.hasPrefix("/ivan-94/cardputer-bridge/releases/") else {
            throw FirmwareOTAStartMessageError.untrustedURL
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(Wire(
            v: 1,
            type: "ota_start",
            version: version,
            url: url
        ))
        guard data.count <= 160 else {
            throw FirmwareOTAStartMessageError.messageTooLarge
        }
        return data
    }

    private struct Wire: Encodable {
        let v: Int
        let type: String
        let version: String
        let url: String

        private enum CodingKeys: String, CodingKey {
            case v
            case type
            case version = "ver"
            case url
        }
    }
}

public enum FirmwareOTAStartMessageError: Error, Equatable {
    case invalidVersion
    case untrustedURL
    case messageTooLarge
}

public enum FirmwareInstallPlan: Equatable, Sendable {
    case upToDate(version: String)
    case usbMigrationRequired(targetVersion: String)
    case otaAvailable(currentVersion: String, targetVersion: String)
    case incompatible(reason: String)
}

public enum FirmwareUpdatePolicy {
    public static func plan(
        device: FirmwareDeviceStatus,
        release: FirmwareReleasePayload,
        appVersion: String = "0.2.0"
    ) -> FirmwareInstallPlan {
        guard release.schemaVersion == 2,
              release.product == "cardputer-bridge",
              release.firmware.chip == "esp32s3" else {
            return .incompatible(reason: "release_not_for_cardputer_bridge")
        }
        guard let installedApp = FirmwareVersion(appVersion),
              let minimumApp = FirmwareVersion(
                release.minimumMacOSAppVersion
              ),
              installedApp >= minimumApp else {
            return .incompatible(reason: "macos_app_update_required")
        }
        guard device.layoutVersion >= release.firmware.layoutVersion,
              device.otaCapable,
              let currentVersion = device.version else {
            return .usbMigrationRequired(targetVersion: release.version)
        }
        guard let current = FirmwareVersion(currentVersion),
              let target = FirmwareVersion(release.version) else {
            return .incompatible(reason: "firmware_version_invalid")
        }
        guard target > current else {
            return .upToDate(version: currentVersion)
        }
        return .otaAvailable(
            currentVersion: currentVersion,
            targetVersion: release.version
        )
    }
}

public enum USBSerialPortCatalog {
    public static func canonicalPorts(from output: String) -> [String] {
        var portsByIdentity: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let port = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !port.isEmpty else { continue }
            if port.hasPrefix("/dev/cu.") {
                let suffix = port.dropFirst("/dev/cu.".count)
                portsByIdentity["serial:\(suffix)"] = port
            } else if port.hasPrefix("/dev/tty.") {
                let suffix = port.dropFirst("/dev/tty.".count)
                let identity = "serial:\(suffix)"
                if portsByIdentity[identity] == nil {
                    portsByIdentity[identity] = port
                }
            } else {
                portsByIdentity["path:\(port)"] = port
            }
        }
        return portsByIdentity.values.sorted()
    }
}

private struct FirmwareVersion: Comparable {
    let components: [Int]
    let prerelease: String?

    init?(_ value: String) {
        let withoutBuild = value.split(separator: "+", maxSplits: 1)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ Int($0) != nil }) else { return nil }
        components = numbers.map { Int(String($0))! }
        prerelease = parts.count == 2 ? String(parts[1]) : nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components {
            return lhs.components.lexicographicallyPrecedes(rhs.components)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(left), .some(right)): return left < right
        }
    }
}
