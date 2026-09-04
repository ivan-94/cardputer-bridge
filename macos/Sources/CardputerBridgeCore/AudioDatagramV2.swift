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

public struct AudioFrameV2: Equatable, Sendable {
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
}

public enum AudioStreamFrameV2 {
    public static let headerBytes = 28
    public static let frameSamples = 320
    public static let payloadBytes = 640
    public static let frameBytes = headerBytes + payloadBytes

    public static func encode(
        pcm16: Data,
        flags: AudioPacketFlags,
        sessionID: UInt64,
        sequence: UInt32,
        captureSampleIndex: UInt32
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
        return header + pcm16
    }

    public static func decode(
        _ packet: Data,
        expectedSessionID: UInt64
    ) throws -> AudioFrameV2 {
        guard packet.count == frameBytes else {
            throw AudioStreamError.invalidLength
        }
        let header = packet.prefix(headerBytes)
        guard header.prefix(4) == Data("CBP2".utf8),
              header[4] == 2,
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
        return AudioFrameV2(
            flags: AudioPacketFlags(rawValue: header[5]),
            sessionID: sessionID,
            sequence: sequence,
            captureSampleIndex: readUInt32(header, at: 20),
            pcm16: Data(packet[headerBytes..<frameBytes])
        )
    }

    private static func makeHeader(
        flags: AudioPacketFlags,
        sessionID: UInt64,
        sequence: UInt32,
        captureSampleIndex: UInt32
    ) -> Data {
        var result = Data("CBP2".utf8)
        result.append(2)
        result.append(flags.rawValue)
        append(UInt16(headerBytes), to: &result)
        append(sessionID, to: &result)
        append(sequence, to: &result)
        append(captureSampleIndex, to: &result)
        append(UInt16(frameSamples), to: &result)
        append(UInt16(payloadBytes), to: &result)
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

public struct AudioDatagramFrameV2: Equatable, Sendable {
    public let frame: AudioFrameV2
    public let isRedundant: Bool
}

/// Plaintext 20 ms PCM frames, optionally preceded by the frame from 100 ms ago.
/// Two frames total 1,336 bytes. Session IDs filter stale traffic; they are not
/// authentication and cannot protect against a LAN observer or injected audio.
public enum AudioRedundantDatagramV2 {
    public static let maximumBytes = AudioStreamFrameV2.frameBytes * 2
    public static let redundancyLagFrames: UInt32 = 5

    public static func make(previous: Data?, current: Data) -> Data {
        guard previous == nil || previous?.count == AudioStreamFrameV2.frameBytes,
              current.count == AudioStreamFrameV2.frameBytes else {
            return Data()
        }
        return (previous ?? Data()) + current
    }

    public static func decode(
        _ datagram: Data,
        expectedSessionID: UInt64
    ) throws -> [AudioDatagramFrameV2] {
        let frameBytes = AudioStreamFrameV2.frameBytes
        guard datagram.count == frameBytes || datagram.count == frameBytes * 2 else {
            throw AudioStreamError.invalidLength
        }

        var result: [AudioDatagramFrameV2] = []
        let frameCount = datagram.count / frameBytes
        result.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let start = index * frameBytes
            let wireFrame = Data(datagram[start..<(start + frameBytes)])
            result.append(AudioDatagramFrameV2(
                frame: try AudioStreamFrameV2.decode(
                    wireFrame,
                    expectedSessionID: expectedSessionID
                ),
                isRedundant: frameCount == 2 && index == 0
            ))
        }
        if result.count == 2 {
            guard result[0].frame.sequence &+ redundancyLagFrames == result[1].frame.sequence,
                  result[0].frame.captureSampleIndex &+
                    UInt32(AudioStreamFrameV2.frameSamples) * redundancyLagFrames ==
                    result[1].frame.captureSampleIndex else {
                throw AudioStreamError.invalidFrameShape
            }
        }
        return result
    }
}
