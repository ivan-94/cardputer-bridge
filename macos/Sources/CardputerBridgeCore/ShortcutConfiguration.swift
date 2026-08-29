import CryptoKit
import Foundation

public enum ShortcutConfigurationError: Error, Equatable {
    case invalidSchema
    case invalidVersion
    case tooManyMappings
    case invalidUsage
    case duplicateIdentifier
    case duplicateTrigger
    case labelTooLong
    case transferTooLarge
}

public struct BridgeShortcutMapping: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var triggerUsage: UInt8
    public var triggerModifiers: UInt8
    public var triggerIncludesG0: Bool
    public var modifiers: UInt8
    public var outputUsage: UInt8
    public var label: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        triggerUsage: UInt8,
        triggerModifiers: UInt8 = 0,
        triggerIncludesG0: Bool = true,
        modifiers: UInt8,
        outputUsage: UInt8,
        label: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.triggerUsage = triggerUsage
        self.triggerModifiers = triggerModifiers
        self.triggerIncludesG0 = triggerIncludesG0
        self.modifiers = modifiers
        self.outputUsage = outputUsage
        self.label = label
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case triggerUsage
        case triggerModifiers
        case triggerIncludesG0
        case modifiers
        case outputUsage
        case label
        case isEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        triggerUsage = try values.decode(UInt8.self, forKey: .triggerUsage)
        triggerModifiers = try values.decodeIfPresent(
            UInt8.self,
            forKey: .triggerModifiers
        ) ?? 0
        triggerIncludesG0 = try values.decodeIfPresent(
            Bool.self,
            forKey: .triggerIncludesG0
        ) ?? true
        modifiers = try values.decode(UInt8.self, forKey: .modifiers)
        outputUsage = try values.decode(UInt8.self, forKey: .outputUsage)
        label = try values.decode(String.self, forKey: .label)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
    }
}

public struct BridgeShortcutConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var configVersion: UInt64
    public var deviceID: String
    public var mappings: [BridgeShortcutMapping]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = 3,
        configVersion: UInt64,
        deviceID: String = "Cardputer-ADV",
        mappings: [BridgeShortcutMapping],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.configVersion = configVersion
        self.deviceID = deviceID
        self.mappings = mappings
        self.updatedAt = updatedAt
    }

    public static var defaults: Self {
        Self(
            configVersion: 2,
            mappings: [
                .init(triggerUsage: 0x14, modifiers: 0x09, outputUsage: 0x14, label: "Quit"),
                .init(triggerUsage: 0x06, modifiers: 0x09, outputUsage: 0x06, label: "Copy"),
                .init(triggerUsage: 0x2c, modifiers: 0x04, outputUsage: 0x2c, label: "Spotlight"),
                .init(triggerUsage: 0x10, modifiers: 0x0a, outputUsage: 0x10, label: "Mute"),
            ]
        )
    }

    public func validated() throws -> Self {
        guard (1...3).contains(schemaVersion) else {
            throw ShortcutConfigurationError.invalidSchema
        }
        guard configVersion > 0 else { throw ShortcutConfigurationError.invalidVersion }
        guard mappings.count <= 32 else { throw ShortcutConfigurationError.tooManyMappings }
        var identifiers = Set<UUID>()
        var triggers = Set<ShortcutTriggerIdentity>()
        for mapping in mappings {
            let validTriggerUsage = (0x04...0xe7).contains(mapping.triggerUsage) ||
                (mapping.triggerIncludesG0 &&
                 mapping.triggerModifiers == 0 &&
                 mapping.triggerUsage == 0)
            guard validTriggerUsage,
                  mapping.triggerModifiers & 0xf0 == 0,
                  (0x04...0xe7).contains(mapping.outputUsage) ||
                    (mapping.outputUsage == 0 && mapping.modifiers != 0) else {
                throw ShortcutConfigurationError.invalidUsage
            }
            guard identifiers.insert(mapping.id).inserted else {
                throw ShortcutConfigurationError.duplicateIdentifier
            }
            let trigger = ShortcutTriggerIdentity(
                includesG0: mapping.triggerIncludesG0,
                modifiers: mapping.triggerModifiers,
                usage: mapping.triggerUsage
            )
            guard triggers.insert(trigger).inserted else {
                throw ShortcutConfigurationError.duplicateTrigger
            }
            guard mapping.label.utf8.count <= 32 else {
                throw ShortcutConfigurationError.labelTooLong
            }
        }
        return self
    }

    public func migratedToCurrentSchema() -> Self {
        guard schemaVersion != 3 else { return self }
        var migrated = self
        migrated.schemaVersion = 3
        return migrated
    }

    public func canonicalData() throws -> Data {
        let valid = try migratedToCurrentSchema().validated()
        var data = Data([0x43, 0x42, 3, UInt8(valid.mappings.count)])
        var bigEndianVersion = valid.configVersion.bigEndian
        withUnsafeBytes(of: &bigEndianVersion) { data.append(contentsOf: $0) }
        for mapping in valid.mappings {
            let label = Data(mapping.label.utf8)
            var identifier = mapping.id.uuid
            withUnsafeBytes(of: &identifier) { data.append(contentsOf: $0) }
            data.append(mapping.triggerIncludesG0 ? 1 : 0)
            data.append(mapping.triggerModifiers)
            data.append(mapping.triggerUsage)
            data.append(mapping.modifiers)
            data.append(mapping.outputUsage)
            data.append(mapping.isEnabled ? 1 : 0)
            data.append(UInt8(label.count))
            data.append(label)
        }
        return data
    }

    public func encodedTransferWrites() throws -> [Data] {
        let canonical = try canonicalData()
        let chunkSize = 72
        let chunks = stride(from: 0, to: canonical.count, by: chunkSize).map {
            canonical.subdata(in: $0..<min($0 + chunkSize, canonical.count))
        }
        guard !chunks.isEmpty, chunks.count <= 32 else {
            throw ShortcutConfigurationError.transferTooLarge
        }
        let digest = Data(SHA256.hash(data: canonical)).base64EncodedString()
        var writes = try [boundedShortcutJSON(ConfigPrepareWire(
            v: 1,
            type: "config_prepare",
            ver: String(format: "%016llx", configVersion),
            bytes: canonical.count,
            chunks: chunks.count,
            sha: digest
        ))]
        for (index, chunk) in chunks.enumerated() {
            writes.append(try boundedShortcutJSON(ConfigChunkWire(
                v: 1,
                type: "config_chunk",
                i: index,
                off: index * chunkSize,
                data: chunk.base64EncodedString()
            )))
        }
        writes.append(try boundedShortcutJSON(ConfigCommitWire(v: 1, type: "config_commit")))
        return writes
    }
}

private struct ShortcutTriggerIdentity: Hashable {
    let includesG0: Bool
    let modifiers: UInt8
    let usage: UInt8
}

private func boundedShortcutJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= 160 else { throw ShortcutConfigurationError.transferTooLarge }
    return data
}

private struct ConfigPrepareWire: Encodable {
    let v: Int
    let type: String
    let ver: String
    let bytes: Int
    let chunks: Int
    let sha: String
}

private struct ConfigChunkWire: Encodable {
    let v: Int
    let type: String
    let i: Int
    let off: Int
    let data: String
}

private struct ConfigCommitWire: Encodable {
    let v: Int
    let type: String
}
