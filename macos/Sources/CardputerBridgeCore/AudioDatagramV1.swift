import CryptoKit
import Foundation

public struct AudioPacketFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let muted = AudioPacketFlags(rawValue: 1 << 0)
    public static let test = AudioPacketFlags(rawValue: 1 << 1)
    public static let end = AudioPacketFlags(rawValue: 1 << 2)
}

public struct AudioFrameV1: Equatable, Sendable {
    public let flags: AudioPacketFlags
    public let sessionID: UInt64
    public let sequence: UInt32
    public let captureSampleIndex: UInt32
    public let pcm16: Data
}

public enum AudioStreamError: Error, Equatable {
    case invalidLength
    case invalidHeader
    case invalidFrameShape
    case sessionMismatch
    case authenticationFailed
}

public enum AudioStreamFrameV1 {
    public static let headerBytes = 28
    public static let frameSamples = 160
    public static let payloadBytes = 320
    public static let tagBytes = 16
    public static let frameBytes = headerBytes + payloadBytes + tagBytes

    public static func seal(
        pcm16: Data,
        flags: AudioPacketFlags,
        sessionID: UInt64,
        sequence: UInt32,
        captureSampleIndex: UInt32,
        key: SymmetricKey
    ) throws -> Data {
        guard pcm16.count == payloadBytes else {
            throw AudioStreamError.invalidFrameShape
        }
        let header = makeHeader(
            flags: flags,
            sessionID: sessionID,
            sequence: sequence,
            captureSampleIndex: captureSampleIndex
        )
        let nonce = try AES.GCM.Nonce(data: makeNonce(
            sessionID: sessionID,
            sequence: sequence
        ))
        let sealed = try AES.GCM.seal(
            pcm16,
            using: key,
            nonce: nonce,
            authenticating: header
        )
        return header + sealed.ciphertext + sealed.tag
    }

    public static func open(
        _ encryptedFrame: Data,
        expectedSessionID: UInt64,
        key: SymmetricKey
    ) throws -> AudioFrameV1 {
        guard encryptedFrame.count == frameBytes else {
            throw AudioStreamError.invalidLength
        }
        let header = encryptedFrame.prefix(headerBytes)
        guard header.prefix(4) == Data("CBS1".utf8),
              header[4] == 1,
              readUInt16(header, at: 6) == headerBytes else {
            throw AudioStreamError.invalidHeader
        }
        let sessionID = readUInt64(header, at: 8)
        guard sessionID == expectedSessionID else {
            throw AudioStreamError.sessionMismatch
        }
        guard readUInt16(header, at: 24) == frameSamples,
              readUInt16(header, at: 26) == payloadBytes else {
            throw AudioStreamError.invalidFrameShape
        }
        let sequence = readUInt32(header, at: 16)
        let ciphertextStart = headerBytes
        let tagStart = headerBytes + payloadBytes
        let ciphertext = encryptedFrame[ciphertextStart..<tagStart]
        let tag = encryptedFrame[tagStart..<frameBytes]
        do {
            let nonce = try AES.GCM.Nonce(data: makeNonce(
                sessionID: sessionID,
                sequence: sequence
            ))
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            let pcm = try AES.GCM.open(
                box,
                using: key,
                authenticating: header
            )
            return AudioFrameV1(
                flags: AudioPacketFlags(rawValue: header[5]),
                sessionID: sessionID,
                sequence: sequence,
                captureSampleIndex: readUInt32(header, at: 20),
                pcm16: pcm
            )
        } catch {
            throw AudioStreamError.authenticationFailed
        }
    }

    private static func makeHeader(
        flags: AudioPacketFlags,
        sessionID: UInt64,
        sequence: UInt32,
        captureSampleIndex: UInt32
    ) -> Data {
        var result = Data("CBS1".utf8)
        result.append(1)
        result.append(flags.rawValue)
        append(UInt16(headerBytes), to: &result)
        append(sessionID, to: &result)
        append(sequence, to: &result)
        append(captureSampleIndex, to: &result)
        append(UInt16(frameSamples), to: &result)
        append(UInt16(payloadBytes), to: &result)
        return result
    }

    private static func makeNonce(sessionID: UInt64, sequence: UInt32) -> Data {
        var result = Data()
        append(sessionID, to: &result)
        append(sequence, to: &result)
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var networkValue = value.bigEndian
        withUnsafeBytes(of: &networkValue) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ data: Data.SubSequence, at offset: Int) -> Int {
        data[offset..<(offset + 2)].reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func readUInt32(_ data: Data.SubSequence, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64(_ data: Data.SubSequence, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

public struct AudioStreamFramer: Sendable {
    public let frameBytes: Int
    public private(set) var bufferedBytes = 0
    private var buffer = Data()

    public init(frameBytes: Int) {
        precondition(frameBytes > 0)
        self.frameBytes = frameBytes
    }

    public mutating func append<S: DataProtocol>(_ bytes: S) -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while buffer.count >= frameBytes {
            frames.append(Data(buffer.prefix(frameBytes)))
            buffer.removeFirst(frameBytes)
        }
        bufferedBytes = buffer.count
        return frames
    }
}
