import XCTest
@testable import CardputerBridgeCore

final class AudioFrameAccumulatorTests: XCTestCase {
    func testTracksAcceptedFramesGapsDuplicatesAndSignalLevel() {
        var accumulator = AudioFrameAccumulator(sessionID: 7)
        let pcm = Array(repeating: Int16(1_000), count: 320)
            .withUnsafeBytes { Data($0) }

        XCTAssertTrue(accumulator.accept(AudioFrameV2(
            flags: [],
            sessionID: 7,
            sequence: 10,
            captureSampleIndex: 0,
            pcm16: pcm
        )))
        XCTAssertTrue(accumulator.accept(AudioFrameV2(
            flags: [],
            sessionID: 7,
            sequence: 12,
            captureSampleIndex: 640,
            pcm16: pcm
        )))
        XCTAssertFalse(accumulator.accept(AudioFrameV2(
            flags: [],
            sessionID: 7,
            sequence: 12,
            captureSampleIndex: 640,
            pcm16: pcm
        )))

        XCTAssertEqual(2, accumulator.metrics.acceptedPackets)
        XCTAssertEqual(1, accumulator.metrics.missingPackets)
        XCTAssertEqual(1, accumulator.metrics.duplicateOrLatePackets)
        XCTAssertEqual(12, accumulator.metrics.lastSequence)
        XCTAssertEqual(1_000.0 / 32_768.0, accumulator.metrics.signalLevel, accuracy: 0.0001)
    }
}
