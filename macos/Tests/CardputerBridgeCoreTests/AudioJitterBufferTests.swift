import XCTest
@testable import CardputerBridgeCore

final class AudioJitterBufferTests: XCTestCase {
    func testDefaultModePrimesAOnePointTwoEightSecondPlayoutReservoir() {
        var buffer = AudioJitterBuffer(sessionID: 7)

        for sequence in UInt32(0)..<UInt32(68) {
            XCTAssertNil(
                buffer.push(
                    frame(sequence: sequence, sample: 1_000),
                    source: .primary
                )
            )
        }

        let startup = buffer.push(
            frame(sequence: 68, sample: 1_000),
            source: .primary
        )

        XCTAssertEqual(64, startup?.frameCount)
        XCTAssertEqual(
            AudioStreamFrameV2.payloadBytes * 64,
            startup?.pcm16.count
        )
    }

    func testMetricsAccumulateAcrossRecordingIntervals() {
        var total = AudioStreamMetrics()
        var first = AudioStreamMetrics()
        first.acceptedPackets = 42
        first.missingPackets = 1
        first.recoveredPackets = 2
        first.missingCaptureSamples = 320
        first.duplicateOrLatePackets = 3
        first.lastSequence = 41
        first.signalLevel = 0.25

        var second = AudioStreamMetrics()
        second.acceptedPackets = 8
        second.recoveredPackets = 1
        second.lastSequence = 49
        second.signalLevel = 0.1

        total.accumulate(first)
        total.accumulate(second)

        XCTAssertEqual(50, total.acceptedPackets)
        XCTAssertEqual(1, total.missingPackets)
        XCTAssertEqual(3, total.recoveredPackets)
        XCTAssertEqual(320, total.missingCaptureSamples)
        XCTAssertEqual(3, total.duplicateOrLatePackets)
        XCTAssertEqual(49, total.lastSequence)
        XCTAssertEqual(0.25, total.signalLevel)
    }

    func testWaitsForRecoveryInsideTheFixedRedundancyWindow() {
        var buffer = shortStartupBuffer()

        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 2, sample: 300), source: .primary))
        for sequence in UInt32(3)...UInt32(5) {
            _ = buffer.push(frame(sequence: sequence, sample: 400), source: .primary)
        }

        XCTAssertNil(buffer.push(frame(sequence: 1, sample: 200), source: .redundant))
        for sequence in UInt32(6)...UInt32(7) {
            _ = buffer.push(frame(sequence: sequence, sample: 400), source: .primary)
        }
        let recovered = buffer.push(frame(sequence: 8, sample: 500), source: .primary)

        XCTAssertNotNil(recovered)
        XCTAssertEqual(1, buffer.metrics.recoveredPackets)
        XCTAssertEqual(0, buffer.metrics.missingPackets)
        XCTAssertEqual(0, buffer.metrics.duplicateOrLatePackets)
    }

    func testConcealsAfterTheAdaptiveReorderDeadlineExpires() {
        var buffer = shortStartupBuffer()

        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 2, sample: 300), source: .primary))
        for sequence in UInt32(3)...UInt32(7) {
            _ = buffer.push(frame(sequence: sequence, sample: 400), source: .primary)
        }
        let output = buffer.push(frame(sequence: 8, sample: 700), source: .primary)

        XCTAssertNotNil(output)
        XCTAssertEqual(1, buffer.metrics.missingPackets)
    }

    func testInterleavedRedundancyRepairsAClusteredDatagramLoss() {
        var buffer = shortStartupBuffer()
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 2, sample: 300), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 3, sample: 400), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 4, sample: 500), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 5, sample: 600), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 1, sample: 200), source: .redundant))
        _ = buffer.push(frame(sequence: 6, sample: 700), source: .primary)
        _ = buffer.push(frame(sequence: 7, sample: 800), source: .primary)
        let startup = buffer.push(frame(sequence: 8, sample: 900), source: .primary)

        XCTAssertEqual(4, startup?.frameCount)
        XCTAssertEqual(2_560, startup?.pcm16.count)
        XCTAssertEqual(1, buffer.metrics.recoveredPackets)
        XCTAssertEqual(0, buffer.metrics.missingPackets)

        XCTAssertNil(buffer.push(frame(sequence: 1, sample: 200), source: .primary))
        XCTAssertEqual(0, buffer.metrics.duplicateOrLatePackets)
    }

    func testRedundancyWindowNeverStarvesPlayoutAfterStartup() {
        var buffer = shortStartupBuffer()
        var reservoirFrames = 0
        var started = false

        // Each datagram carries the current primary frame plus the frame from
        // five intervals ago. Lose primary 9, but deliver its redundant copy
        // with primary 14. Once playout has started, every subsequent primary
        // datagram must advance output instead of pausing the microphone while
        // it waits for that recovery copy.
        for sequence in UInt32(0)...UInt32(18) {
            var emittedFrames = 0
            if sequence != 9, sequence >= 5 {
                let redundantSequence = sequence - 5
                emittedFrames += buffer.push(
                    frame(sequence: redundantSequence, sample: Int16(redundantSequence + 1)),
                    source: .redundant
                )?.frameCount ?? 0
            }
            if sequence != 9,
               let batch = buffer.push(
                   frame(sequence: sequence, sample: Int16(sequence + 1)),
                   source: .primary
               ) {
                emittedFrames += batch.frameCount
            }

            if emittedFrames > 0 {
                started = true
                reservoirFrames += emittedFrames
            }
            if started {
                reservoirFrames -= 1
                XCTAssertGreaterThan(
                    reservoirFrames,
                    0,
                    "playout reservoir starved after datagram \(sequence)"
                )
            }
        }

        XCTAssertEqual(1, buffer.metrics.recoveredPackets)
        XCTAssertEqual(0, buffer.metrics.missingPackets)
    }

    func testGapWaitsUntilTheFiveFrameRedundancyDeadline() {
        var buffer = shortStartupBuffer()
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 2, sample: 300), source: .primary))
        for sequence in UInt32(3)...UInt32(5) {
            XCTAssertNil(buffer.push(frame(sequence: sequence, sample: 400), source: .primary))
        }

        XCTAssertEqual(0, buffer.metrics.missingPackets)
        XCTAssertNil(buffer.push(frame(sequence: 6, sample: 400), source: .primary))
        XCTAssertEqual(1, buffer.metrics.missingPackets)
    }

    func testConcealmentPreservesSignalInsteadOfWritingDigitalSilence() {
        var buffer = shortStartupBuffer()
        for sequence in [UInt32(0), 2, 3, 4, 5, 6, 7] {
            _ = buffer.push(frame(sequence: sequence, sample: 1_000), source: .primary)
        }
        let startup = buffer.push(frame(sequence: 8, sample: 1_000), source: .primary)

        XCTAssertEqual(4, startup?.frameCount)
        let concealedFrame = startup?.pcm16.subdata(
            in: AudioStreamFrameV2.payloadBytes..<(AudioStreamFrameV2.payloadBytes * 2)
        )
        XCTAssertFalse(concealedFrame?.allSatisfy { $0 == 0 } ?? true)
        XCTAssertEqual(1, buffer.metrics.missingPackets)
    }

    func testCaptureClockGapRemainsObservable() {
        var buffer = shortStartupBuffer()
        for (sequence, captureIndex) in [
            (10, 0), (11, 320), (12, 960), (13, 1_280),
            (14, 1_600), (15, 1_920), (16, 2_240), (17, 2_560),
        ] {
            _ = buffer.push(
                frame(sequence: UInt32(sequence), captureSampleIndex: UInt32(captureIndex), sample: 1_000),
                source: .primary
            )
        }

        XCTAssertEqual(0, buffer.metrics.missingPackets)
        XCTAssertEqual(320, buffer.metrics.missingCaptureSamples)
    }

    func testExpectedRedundantDuplicateIsNotReportedAsNetworkDefect() {
        var buffer = shortStartupBuffer()
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .redundant))

        XCTAssertEqual(1, buffer.metrics.acceptedPackets)
        XCTAssertEqual(0, buffer.metrics.duplicateOrLatePackets)
    }

    func testRejectsUnexpectedPrimaryDuplicate() {
        var buffer = shortStartupBuffer()
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))

        XCTAssertEqual(1, buffer.metrics.acceptedPackets)
        XCTAssertEqual(1, buffer.metrics.duplicateOrLatePackets)
    }

    func testPrimaryReplacesRedundantFrameInsideReorderWindow() {
        var buffer = shortStartupBuffer()
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .redundant))
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        for sequence in UInt32(1)...UInt32(5) {
            _ = buffer.push(frame(sequence: sequence, sample: 200), source: .primary)
        }

        XCTAssertEqual(0, buffer.metrics.recoveredPackets)
        XCTAssertEqual(0, buffer.metrics.duplicateOrLatePackets)
    }

    func testHugeGapCatchesUpWithoutBufferingSecondsOfSilence() {
        var buffer = shortStartupBuffer()
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 1, sample: 200), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 100, sample: 300), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 101, sample: 400), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 102, sample: 500), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 103, sample: 600), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 104, sample: 700), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 105, sample: 800), source: .primary))
        let startup = buffer.push(frame(sequence: 106, sample: 900), source: .primary)

        XCTAssertEqual(4, startup?.frameCount)
        XCTAssertEqual(98, buffer.metrics.missingPackets)
    }

    func testFinishReleasesTheFiveFrameRedundancyTail() {
        var buffer = shortStartupBuffer()
        for sequence in UInt32(0)...UInt32(8) {
            _ = buffer.push(
                frame(sequence: sequence, sample: Int16(sequence + 1)),
                source: .primary
            )
        }

        let tail = buffer.finish()

        XCTAssertEqual(5, tail?.frameCount)
        XCTAssertEqual(3_200, tail?.pcm16.count)
        XCTAssertEqual(0, buffer.metrics.missingPackets)
    }

    func testFinishReleasesAShortRecordingBeforeStartupThreshold() {
        var buffer = shortStartupBuffer()
        XCTAssertNil(buffer.push(frame(sequence: 0, sample: 100), source: .primary))
        XCTAssertNil(buffer.push(frame(sequence: 1, sample: 200), source: .primary))

        let tail = buffer.finish()

        XCTAssertEqual(2, tail?.frameCount)
        XCTAssertEqual(1_280, tail?.pcm16.count)
        XCTAssertEqual(0, buffer.metrics.missingPackets)
    }

    private func frame(sequence: UInt32, sample: Int16) -> AudioFrameV2 {
        frame(
            sequence: sequence,
            captureSampleIndex: sequence * UInt32(AudioStreamFrameV2.frameSamples),
            sample: sample
        )
    }

    private func shortStartupBuffer() -> AudioJitterBuffer {
        AudioJitterBuffer(sessionID: 7, startupFrameCount: 4)
    }

    private func frame(
        sequence: UInt32,
        captureSampleIndex: UInt32,
        sample: Int16
    ) -> AudioFrameV2 {
        let pcm = Array(
            repeating: sample,
            count: AudioStreamFrameV2.frameSamples
        ).withUnsafeBytes { Data($0) }
        return AudioFrameV2(
            flags: [],
            sessionID: 7,
            sequence: sequence,
            captureSampleIndex: captureSampleIndex,
            pcm16: pcm
        )
    }
}
