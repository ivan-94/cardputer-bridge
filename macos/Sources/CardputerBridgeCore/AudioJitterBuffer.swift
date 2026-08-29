import Foundation

public struct AudioJitterBatch: Equatable, Sendable {
    public let pcm16: Data
    public let frameCount: Int
}

/// A 40 ms reorder window followed by a 60 ms startup reservoir.
///
/// The virtual microphone ring receives the startup reservoir in one write,
/// so Core Audio cannot start consuming a nearly empty stream. Once started,
/// packets remain two frames behind the newest authenticated packet. A packet
/// that is still absent at that point is replaced with a short fade to silence.
public struct AudioJitterBuffer: Sendable {
    public let sessionID: UInt64
    public private(set) var metrics = AudioStreamMetrics()

    private static let samplesPerFrame = 320
    private static let bytesPerFrame = samplesPerFrame * MemoryLayout<Int16>.size
    private static let reorderDepth: UInt32 = 2
    private static let startupFrameCount = 3
    private static let fadeSamples = 80

    private var pending: [UInt32: Data] = [:]
    private var nextSequence: UInt32?
    private var highestSequence: UInt32?
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

    public mutating func push(_ frame: AudioFrameV1) -> AudioJitterBatch? {
        guard frame.sessionID == sessionID,
              frame.pcm16.count == Self.bytesPerFrame else {
            return nil
        }
        if let nextSequence, frame.sequence < nextSequence {
            metrics.duplicateOrLatePackets += 1
            return nil
        }
        guard pending[frame.sequence] == nil else {
            metrics.duplicateOrLatePackets += 1
            return nil
        }

        if nextSequence == nil {
            nextSequence = frame.sequence
        }
        highestSequence = max(highestSequence ?? frame.sequence, frame.sequence)
        pending[frame.sequence] = frame.pcm16
        metrics.acceptedPackets += 1
        metrics.lastSequence = frame.sequence
        metrics.signalLevel = signalLevel(frame.pcm16)

        var ready = Data()
        var readyFrames = 0
        while canReleaseNextFrame {
            guard let sequence = nextSequence else { break }
            let output: Data
            if let real = pending.removeValue(forKey: sequence) {
                output = fadeInNextRealFrame ? fadedIn(real) : real
                fadeInNextRealFrame = false
            } else {
                output = concealedFrame()
                metrics.missingPackets += 1
                fadeInNextRealFrame = true
            }
            lastOutputSample = lastSample(in: output)
            ready.append(output)
            readyFrames += 1
            nextSequence = sequence &+ 1
        }

        guard readyFrames > 0 else { return nil }
        if !started {
            startupReservoir.append(ready)
            startupReservoirFrames += readyFrames
            guard startupReservoirFrames >= Self.startupFrameCount else {
                return nil
            }
            started = true
            let batch = AudioJitterBatch(
                pcm16: startupReservoir,
                frameCount: startupReservoirFrames
            )
            startupReservoir.removeAll(keepingCapacity: false)
            startupReservoirFrames = 0
            return batch
        }
        return AudioJitterBatch(pcm16: ready, frameCount: readyFrames)
    }

    private var canReleaseNextFrame: Bool {
        guard let nextSequence, let highestSequence else { return false }
        return highestSequence >= nextSequence
            && highestSequence - nextSequence >= Self.reorderDepth
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
