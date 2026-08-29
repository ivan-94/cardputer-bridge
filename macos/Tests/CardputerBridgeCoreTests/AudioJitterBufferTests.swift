import Foundation
import XCTest
@testable import CardputerBridgeCore

final class AudioJitterBufferTests: XCTestCase {
    func testStartsWithAContiguousSixtyMillisecondBatch() {
        var buffer = AudioJitterBuffer(sessionID: 7)

        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100)))
        XCTAssertNil(buffer.push(frame(sequence: 1, sample: 200)))
        XCTAssertNil(buffer.push(frame(sequence: 2, sample: 300)))
        XCTAssertNil(buffer.push(frame(sequence: 3, sample: 400)))
        let startup = buffer.push(frame(sequence: 4, sample: 500))

        XCTAssertEqual(startup?.frameCount, 3)
        XCTAssertEqual(startup?.pcm16.count, 3 * 320 * MemoryLayout<Int16>.size)
        XCTAssertEqual(samples(in: startup?.pcm16).first, 100)
        XCTAssertEqual(samples(in: startup?.pcm16)[320], 200)
        XCTAssertEqual(samples(in: startup?.pcm16)[640], 300)
    }

    func testReordersPacketsInsideTheJitterWindow() {
        var buffer = AudioJitterBuffer(sessionID: 7)

        XCTAssertNil(buffer.push(frame(sequence: 10, sample: 10)))
        XCTAssertNil(buffer.push(frame(sequence: 12, sample: 12)))
        XCTAssertNil(buffer.push(frame(sequence: 11, sample: 11)))
        XCTAssertNil(buffer.push(frame(sequence: 13, sample: 13)))
        let startup = buffer.push(frame(sequence: 14, sample: 14))

        let decoded = samples(in: startup?.pcm16)
        XCTAssertEqual(decoded[0], 10)
        XCTAssertEqual(decoded[320], 11)
        XCTAssertEqual(decoded[640], 12)
        XCTAssertEqual(buffer.metrics.duplicateOrLatePackets, 0)
    }

    func testConcealsAConfirmedMissingPacketWithoutAHardEdge() {
        var buffer = AudioJitterBuffer(sessionID: 7)

        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 1_000)))
        XCTAssertNil(buffer.push(frame(sequence: 2, sample: 3_000)))
        XCTAssertNil(buffer.push(frame(sequence: 3, sample: 3_000)))
        let startup = buffer.push(frame(sequence: 4, sample: 3_000))

        let decoded = samples(in: startup?.pcm16)
        let concealed = Array(decoded[320..<640])
        let resumed = Array(decoded[640..<960])
        XCTAssertLessThanOrEqual(abs(Int(concealed[0]) - 1_000), 20)
        XCTAssertEqual(concealed[79], 0, accuracy: 20)
        XCTAssertEqual(concealed[319], 0)
        XCTAssertEqual(resumed[0], 0, accuracy: 20)
        XCTAssertGreaterThan(resumed[79], 2_900)
        XCTAssertEqual(buffer.metrics.missingPackets, 1)
    }

    func testRejectsDuplicateAndWrongSessionPackets() {
        var buffer = AudioJitterBuffer(sessionID: 7)
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100)))
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100)))
        XCTAssertNil(buffer.push(AudioFrameV1(
            flags: [],
            sessionID: 8,
            sequence: 1,
            captureSampleIndex: 320,
            pcm16: pcm(sample: 100)
        )))

        XCTAssertEqual(buffer.metrics.acceptedPackets, 1)
        XCTAssertEqual(buffer.metrics.duplicateOrLatePackets, 1)
    }

    private func frame(sequence: UInt32, sample: Int16) -> AudioFrameV1 {
        AudioFrameV1(
            flags: [],
            sessionID: 7,
            sequence: sequence,
            captureSampleIndex: sequence * 320,
            pcm16: pcm(sample: sample)
        )
    }

    private func pcm(sample: Int16) -> Data {
        Array(repeating: sample, count: 320).withUnsafeBytes { Data($0) }
    }

    private func samples(in data: Data?) -> [Int16] {
        guard let data else { return [] }
        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Int16.self))
        }
    }
}
