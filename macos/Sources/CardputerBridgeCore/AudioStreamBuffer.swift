import Foundation

public struct AudioStreamBatch: Equatable, Sendable {
    public let pcm16: Data
    public let frameCount: Int
}

/// Buffers only the first 30 ms needed to start the Core Audio producer with
/// headroom. TCP already provides ordering and retransmission, so steady-state
/// frames are released immediately instead of waiting in a jitter window.
public struct AudioStreamBuffer: Sendable {
    public let sessionID: UInt64
    public private(set) var metrics = AudioStreamMetrics()

    private static let samplesPerFrame = AudioStreamFrameV1.frameSamples
    private static let bytesPerFrame = AudioStreamFrameV1.payloadBytes
    private static let startupFrameCount = 3
    private static let fadeSamples = 40
    private static let maximumConcealedGapFrames = 50

    private var expectedSequence: UInt32?
    private var startupReservoir = Data()
    private var startupReservoirFrames = 0
    private var started = false
    private var fadeInNextRealFrame = false
    private var lastOutputSample: Int16 = 0

    public init(sessionID: UInt64) {
        self.sessionID = sessionID
        startupReservoir.reserveCapacity(
            Self.bytesPerFrame * Self.startupFrameCount
        )
    }

    public mutating func push(_ frame: AudioFrameV1) -> AudioStreamBatch? {
        guard frame.sessionID == sessionID,
              frame.pcm16.count == Self.bytesPerFrame else {
            return nil
        }
        if let expectedSequence, frame.sequence < expectedSequence {
            metrics.duplicateOrLatePackets += 1
            return nil
        }

        var ready = Data()
        var readyFrames = 0
        if let expectedSequence, frame.sequence > expectedSequence {
            let missing = Int(frame.sequence - expectedSequence)
            metrics.missingPackets += missing
            for _ in 0..<min(missing, Self.maximumConcealedGapFrames) {
                let concealed = concealedFrame()
                ready.append(concealed)
                lastOutputSample = lastSample(in: concealed)
                readyFrames += 1
            }
            fadeInNextRealFrame = true
        }

        let output = fadeInNextRealFrame ? fadedIn(frame.pcm16) : frame.pcm16
        fadeInNextRealFrame = false
        ready.append(output)
        readyFrames += 1
        lastOutputSample = lastSample(in: output)
        expectedSequence = frame.sequence &+ 1
        metrics.acceptedPackets += 1
        metrics.lastSequence = frame.sequence
        metrics.signalLevel = signalLevel(frame.pcm16)

        if !started {
            startupReservoir.append(ready)
            startupReservoirFrames += readyFrames
            guard startupReservoirFrames >= Self.startupFrameCount else {
                return nil
            }
            started = true
            let batch = AudioStreamBatch(
                pcm16: startupReservoir,
                frameCount: startupReservoirFrames
            )
            startupReservoir.removeAll(keepingCapacity: false)
            startupReservoirFrames = 0
            return batch
        }
        return AudioStreamBatch(pcm16: ready, frameCount: readyFrames)
    }

    private func signalLevel(_ pcm16: Data) -> Double {
        var squareSum = 0.0
        var sampleCount = 0
        pcm16.withUnsafeBytes { bytes in
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                let sample = Double(Int16(bitPattern: bits)) / 32_768.0
                squareSum += sample * sample
                sampleCount += 1
            }
        }
        return sampleCount == 0 ? 0 : (squareSum / Double(sampleCount)).squareRoot()
    }

    private func concealedFrame() -> Data {
        var samples = Array(repeating: Int16(0), count: Self.samplesPerFrame)
        for index in 0..<Self.fadeSamples {
            let remaining = Double(Self.fadeSamples - 1 - index)
                / Double(Self.fadeSamples - 1)
            samples[index] = Int16((Double(lastOutputSample) * remaining).rounded())
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func fadedIn(_ pcm16: Data) -> Data {
        var samples = decodedSamples(pcm16)
        for index in 0..<min(Self.fadeSamples, samples.count) {
            let progress = Double(index) / Double(Self.fadeSamples - 1)
            samples[index] = Int16((Double(samples[index]) * progress).rounded())
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func lastSample(in pcm16: Data) -> Int16 {
        decodedSamples(pcm16).last ?? 0
    }

    private func decodedSamples(_ pcm16: Data) -> [Int16] {
        pcm16.withUnsafeBytes { bytes in
            var result: [Int16] = []
            result.reserveCapacity(bytes.count / 2)
            for index in stride(from: 0, to: bytes.count, by: 2) {
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                result.append(Int16(bitPattern: bits))
            }
            return result
        }
    }
}
