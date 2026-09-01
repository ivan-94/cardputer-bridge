import XCTest
@testable import CardputerBridgeCore

final class AudioStreamBufferTests: XCTestCase {
    func testStartsAfterThirtyMillisecondsThenReleasesEveryOrderedFrame() {
        var buffer = AudioStreamBuffer(sessionID: 7)

        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100)))
        XCTAssertNil(buffer.push(frame(sequence: 1, sample: 200)))
        let startup = buffer.push(frame(sequence: 2, sample: 300))
        let next = buffer.push(frame(sequence: 3, sample: 400))

        XCTAssertEqual(3, startup?.frameCount)
        XCTAssertEqual(960, startup?.pcm16.count)
        XCTAssertEqual(1, next?.frameCount)
        XCTAssertEqual(320, next?.pcm16.count)
        XCTAssertEqual(4, buffer.metrics.acceptedPackets)
        XCTAssertEqual(0, buffer.metrics.missingPackets)
    }

    func testCaptureSequenceGapIsObservableAndConcealedWithoutReorderingDelay() {
        var buffer = AudioStreamBuffer(sessionID: 7)
        XCTAssertNil(buffer.push(frame(sequence: 10, sample: 1_000)))
        XCTAssertNil(buffer.push(frame(sequence: 11, sample: 1_000)))
        _ = buffer.push(frame(sequence: 12, sample: 1_000))

        let output = buffer.push(frame(sequence: 14, sample: 3_000))

        XCTAssertEqual(2, output?.frameCount)
        XCTAssertEqual(1, buffer.metrics.missingPackets)
        XCTAssertEqual(4, buffer.metrics.acceptedPackets)
    }

    func testRejectsDuplicateOrOldFrames() {
        var buffer = AudioStreamBuffer(sessionID: 7)
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100)))
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100)))

        XCTAssertEqual(1, buffer.metrics.acceptedPackets)
        XCTAssertEqual(1, buffer.metrics.duplicateOrLatePackets)
    }

    private func frame(sequence: UInt32, sample: Int16) -> AudioFrameV1 {
        let pcm = Array(
            repeating: sample,
            count: AudioStreamFrameV1.frameSamples
        ).withUnsafeBytes { Data($0) }
        return AudioFrameV1(
            flags: [],
            sessionID: 7,
            sequence: sequence,
            captureSampleIndex: sequence * UInt32(AudioStreamFrameV1.frameSamples),
            pcm16: pcm
        )
    }
}
