import CryptoKit
import XCTest
@testable import CardputerBridgeCore

final class AudioStreamFrameTests: XCTestCase {
    func testTenMillisecondStreamFrameUsesProtocolHeaderAndRoundTripsPCM() throws {
        let samples = (0..<160).map { Int16(truncatingIfNeeded: $0 * 97) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let key = SymmetricKey(data: Data(0..<32))

        let packet = try AudioStreamFrameV1.seal(
            pcm16: pcm,
            flags: [.test],
            sessionID: 0x0102030405060708,
            sequence: 0x0a0b0c0d,
            captureSampleIndex: 0x10111213,
            key: key
        )

        XCTAssertEqual(364, packet.count)
        XCTAssertEqual(
            Data([
                0x43, 0x42, 0x53, 0x31,
                0x01, 0x02, 0x00, 0x1c,
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x0a, 0x0b, 0x0c, 0x0d,
                0x10, 0x11, 0x12, 0x13,
                0x00, 0xa0, 0x01, 0x40,
            ]),
            packet.prefix(AudioStreamFrameV1.headerBytes)
        )

        let frame = try AudioStreamFrameV1.open(
            packet,
            expectedSessionID: 0x0102030405060708,
            key: key
        )
        XCTAssertEqual(0x0a0b0c0d, frame.sequence)
        XCTAssertEqual(0x10111213, frame.captureSampleIndex)
        XCTAssertEqual([.test], frame.flags)
        XCTAssertEqual(pcm, frame.pcm16)
    }

    func testRejectsAuthenticationFailureAndWrongSession() throws {
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        var packet = try AudioStreamFrameV1.seal(
            pcm16: Data(repeating: 0, count: 320),
            flags: [.muted],
            sessionID: 7,
            sequence: 1,
            captureSampleIndex: 0,
            key: key
        )

        XCTAssertThrowsError(
            try AudioStreamFrameV1.open(packet, expectedSessionID: 8, key: key)
        )
        packet[packet.count - 1] ^= 0xff
        XCTAssertThrowsError(
            try AudioStreamFrameV1.open(packet, expectedSessionID: 7, key: key)
        )
    }

    func testStreamFramerReassemblesFragmentedAndCoalescedTCPReads() {
        let first = Data(repeating: 0x11, count: AudioStreamFrameV1.frameBytes)
        let second = Data(repeating: 0x22, count: AudioStreamFrameV1.frameBytes)
        var framer = AudioStreamFramer(frameBytes: AudioStreamFrameV1.frameBytes)

        XCTAssertEqual([], framer.append(first.prefix(37)))
        XCTAssertEqual(
            [first, second],
            framer.append(first.dropFirst(37) + second)
        )
        XCTAssertEqual(0, framer.bufferedBytes)
    }
}
