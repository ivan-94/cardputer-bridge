import XCTest
@testable import CardputerBridgeCore

final class AudioStreamFrameTests: XCTestCase {
    func testPlaintextWireFrameMatchesFirmwareHeaderAndPCM() throws {
        var pcm = Data(repeating: 0, count: 640)
        pcm.replaceSubrange(0..<6, with: [0, 0x80, 0xff, 0x7f, 0xff, 0xff])
        let packet = try AudioStreamFrameV2.encode(
            pcm16: pcm, flags: [.test], sessionID: 0x0102030405060708,
            sequence: 0x0a0b0c0d, captureSampleIndex: 0x10111213
        )
        XCTAssertEqual(668, packet.count)
        XCTAssertEqual(Data([
            0x43, 0x42, 0x50, 0x32, 0x02, 0x02, 0x00, 0x1c,
            1, 2, 3, 4, 5, 6, 7, 8,
            0x0a, 0x0b, 0x0c, 0x0d, 0x10, 0x11, 0x12, 0x13,
            0x01, 0x40, 0x02, 0x80
        ]), packet.prefix(28))
        XCTAssertEqual(pcm, packet.suffix(640))
        let frame = try AudioStreamFrameV2.decode(packet, expectedSessionID: 0x0102030405060708)
        XCTAssertEqual(pcm, frame.pcm16)
        XCTAssertEqual(0x0a0b0c0d, frame.sequence)
        XCTAssertEqual(0x10111213, frame.captureSampleIndex)
        XCTAssertEqual([.test], frame.flags)
    }

    func testRejectsLegacyCiphertextWrongSessionAndMalformedFrames() throws {
        let packet = try wireFrame(sequence: 1)
        XCTAssertThrowsError(try AudioStreamFrameV2.decode(packet, expectedSessionID: 8))
        for offset in [0, 4, 6, 24, 26] {
            var invalid = packet
            invalid[offset] ^= 0xff
            XCTAssertThrowsError(try AudioStreamFrameV2.decode(invalid, expectedSessionID: 7))
        }
        for length in [0, 27, 667, 669, 684, 1368] {
            XCTAssertThrowsError(try AudioStreamFrameV2.decode(
                Data(repeating: 0, count: length), expectedSessionID: 7
            ))
        }
        var legacy = packet
        legacy.replaceSubrange(0..<5, with: Array("CBS1".utf8) + [1])
        XCTAssertThrowsError(try AudioStreamFrameV2.decode(legacy, expectedSessionID: 7))
        XCTAssertThrowsError(try AudioStreamFrameV2.encode(
            pcm16: Data(), flags: [], sessionID: 7, sequence: 0, captureSampleIndex: 0
        ))
    }

    func testPlaintextDoesNotClaimTamperAuthentication() throws {
        var packet = try wireFrame(sequence: 1)
        packet[28] ^= 0xff
        let frame = try AudioStreamFrameV2.decode(packet, expectedSessionID: 7)
        XCTAssertEqual(packet[28], frame.pcm16[0])
    }

    func testDatagramCarriesDelayedCopyWithoutFragmentation() throws {
        let previous = try wireFrame(sequence: 40)
        let current = try wireFrame(sequence: 45)
        let datagram = AudioRedundantDatagramV2.make(previous: previous, current: current)
        XCTAssertEqual(1336, datagram.count)
        XCTAssertLessThanOrEqual(datagram.count, 1472)
        let frames = try AudioRedundantDatagramV2.decode(datagram, expectedSessionID: 7)
        XCTAssertEqual([40, 45], frames.map(\.frame.sequence))
        XCTAssertEqual([true, false], frames.map(\.isRedundant))
        let wrongLag = try wireFrame(sequence: 44)
        XCTAssertThrowsError(try AudioRedundantDatagramV2.decode(
            previous + wrongLag, expectedSessionID: 7
        ))
        XCTAssertEqual(1, try AudioRedundantDatagramV2.decode(current, expectedSessionID: 7).count)
        XCTAssertThrowsError(try AudioRedundantDatagramV2.decode(Data(), expectedSessionID: 7))
    }

    private func wireFrame(sequence: UInt32) throws -> Data {
        try AudioStreamFrameV2.encode(
            pcm16: Data(repeating: UInt8(sequence), count: 640), flags: [],
            sessionID: 7, sequence: sequence, captureSampleIndex: sequence * 320
        )
    }
}
