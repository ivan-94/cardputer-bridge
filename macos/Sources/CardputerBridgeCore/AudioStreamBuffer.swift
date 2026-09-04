import Foundation

public struct AudioStreamBatch: Equatable, Sendable {
    public let pcm16: Data
    public let frameCount: Int
}

public enum AudioFrameSource: Equatable, Sendable {
    case primary
    case redundant
}

/// Reorders UDP frames behind the sender's fixed redundancy window, then
/// primes the system microphone with a 1.28-second reservoir. A real packet
/// capture observed a 1.143-second Wi-Fi ingress pause followed by complete
/// delivery, so voice integrity requires a reservoir longer than that pause.
public struct AudioJitterBuffer: Sendable {
    public let sessionID: UInt64
    public private(set) var metrics = AudioStreamMetrics()

    private static let samplesPerFrame = AudioStreamFrameV2.frameSamples
    private static let bytesPerFrame = AudioStreamFrameV2.payloadBytes
    private static let reliableVoiceStartupFrameCount = 64
    private static let reorderDepth = 5
    private static let fadeSamples = 80
    private static let maximumConcealedGapFrames = 5

    private struct PendingFrame: Sendable {
        let frame: AudioFrameV2
        let source: AudioFrameSource
    }

    private var nextSequence: UInt32?
    private var highestSequence: UInt32?
    private var expectedCaptureSampleIndex: UInt32?
    private var pending: [UInt32: PendingFrame] = [:]
    private let startupFrameCount: Int
    private var startupReservoir = Data()
    private var startupReservoirFrames = 0
    private var started = false
    private var fadeInNextRealFrame = false
    private var lastOutputSample: Int16 = 0
    private var lastOutputFrame = Data()
    private var redundantlyOutputSequences: Set<UInt32> = []

    public init(sessionID: UInt64) {
        self.init(
            sessionID: sessionID,
            startupFrameCount: Self.reliableVoiceStartupFrameCount
        )
    }

    init(sessionID: UInt64, startupFrameCount: Int) {
        precondition(startupFrameCount > 0)
        self.sessionID = sessionID
        self.startupFrameCount = startupFrameCount
        startupReservoir.reserveCapacity(
            Self.bytesPerFrame * startupFrameCount
        )
    }

    public mutating func push(
        _ frame: AudioFrameV2,
        source: AudioFrameSource
    ) -> AudioStreamBatch? {
        guard frame.sessionID == sessionID,
              frame.pcm16.count == Self.bytesPerFrame else {
            return nil
        }
        if let nextSequence, frame.sequence < nextSequence {
            if source == .primary,
               redundantlyOutputSequences.remove(frame.sequence) != nil {
                // UDP reordering can deliver N+1 (which redundantly carries N)
                // before N's original datagram. The late primary is expected,
                // because the audio was already recovered before its deadline.
                return nil
            }
            // Seeing the previous frame again is the normal redundancy path,
            // not a transport defect. Preserve the diagnostic for unexpected
            // primary duplicates and genuinely late primary packets.
            if source == .primary {
                metrics.duplicateOrLatePackets += 1
            }
            return nil
        }
        if let existing = pending[frame.sequence] {
            if source == .primary && existing.source == .redundant {
                // The primary arrived inside the reorder window, so this was
                // ordinary reordering rather than a recovery event.
                pending[frame.sequence] = PendingFrame(
                    frame: frame,
                    source: .primary
                )
                return nil
            }
            if source == .primary {
                metrics.duplicateOrLatePackets += 1
            }
            return nil
        }
        pending[frame.sequence] = PendingFrame(frame: frame, source: source)
        if nextSequence == nil { nextSequence = frame.sequence }
        highestSequence = max(highestSequence ?? frame.sequence, frame.sequence)
        metrics.acceptedPackets += 1
        metrics.lastSequence = max(metrics.lastSequence ?? frame.sequence, frame.sequence)
        metrics.signalLevel = signalLevel(frame.pcm16)

        var ready = Data()
        var readyFrames = 0
        while let next = nextSequence,
              let highest = highestSequence,
              highest >= next,
              Int(highest - next) >= Self.reorderDepth {
            if let queued = pending.removeValue(forKey: next) {
                recordRecoveryIfNeeded(queued, sequence: next)
                if let expectedCaptureSampleIndex,
                   queued.frame.captureSampleIndex > expectedCaptureSampleIndex {
                    metrics.missingCaptureSamples += Int(
                        queued.frame.captureSampleIndex - expectedCaptureSampleIndex
                    )
                }
                let output = fadeInNextRealFrame
                    ? fadedIn(queued.frame.pcm16)
                    : queued.frame.pcm16
                fadeInNextRealFrame = false
                ready.append(output)
                lastOutputSample = lastSample(in: output)
                lastOutputFrame = output
                expectedCaptureSampleIndex = queued.frame.captureSampleIndex &+
                    UInt32(Self.samplesPerFrame)
            } else if let catchUpSequence = pending.keys
                .filter({ $0 > next })
                .min(),
                Int(catchUpSequence - next) > Self.maximumConcealedGapFrames {
                metrics.missingPackets += Int(catchUpSequence - next)
                nextSequence = catchUpSequence
                fadeInNextRealFrame = true
                continue
            } else {
                metrics.missingPackets += 1
                let concealed = concealedFrame()
                ready.append(concealed)
                lastOutputSample = lastSample(in: concealed)
                lastOutputFrame = concealed
                if let expectedCaptureSampleIndex {
                    self.expectedCaptureSampleIndex = expectedCaptureSampleIndex &+
                        UInt32(Self.samplesPerFrame)
                }
                fadeInNextRealFrame = true
            }
            readyFrames += 1
            nextSequence = next &+ 1
        }

        guard readyFrames > 0 else { return nil }

        if !started {
            startupReservoir.append(ready)
            startupReservoirFrames += readyFrames
            guard startupReservoirFrames >= startupFrameCount else {
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

    public mutating func push(_ frame: AudioFrameV2) -> AudioStreamBatch? {
        push(frame, source: .primary)
    }

    /// Releases the bounded reorder tail when the sender closes one recording
    /// interval. Without this explicit flush the final two 20 ms frames would
    /// remain intentionally held forever.
    public mutating func finish() -> AudioStreamBatch? {
        var ready = Data()
        var readyFrames = 0
        while let next = nextSequence,
              let highest = highestSequence,
              highest >= next {
            if let queued = pending.removeValue(forKey: next) {
                recordRecoveryIfNeeded(queued, sequence: next)
                if let expectedCaptureSampleIndex,
                   queued.frame.captureSampleIndex > expectedCaptureSampleIndex {
                    metrics.missingCaptureSamples += Int(
                        queued.frame.captureSampleIndex - expectedCaptureSampleIndex
                    )
                }
                let output = fadeInNextRealFrame
                    ? fadedIn(queued.frame.pcm16)
                    : queued.frame.pcm16
                fadeInNextRealFrame = false
                ready.append(output)
                lastOutputSample = lastSample(in: output)
                lastOutputFrame = output
                expectedCaptureSampleIndex = queued.frame.captureSampleIndex &+
                    UInt32(Self.samplesPerFrame)
            } else {
                metrics.missingPackets += 1
                let concealed = concealedFrame()
                ready.append(concealed)
                lastOutputSample = lastSample(in: concealed)
                lastOutputFrame = concealed
                if let expectedCaptureSampleIndex {
                    self.expectedCaptureSampleIndex = expectedCaptureSampleIndex &+
                        UInt32(Self.samplesPerFrame)
                }
                fadeInNextRealFrame = true
            }
            readyFrames += 1
            nextSequence = next &+ 1
        }

        if !started {
            startupReservoir.append(ready)
            startupReservoirFrames += readyFrames
            guard startupReservoirFrames > 0 else { return nil }
            started = true
            let batch = AudioStreamBatch(
                pcm16: startupReservoir,
                frameCount: startupReservoirFrames
            )
            startupReservoir.removeAll(keepingCapacity: false)
            startupReservoirFrames = 0
            return batch
        }
        guard readyFrames > 0 else { return nil }
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

    private mutating func recordRecoveryIfNeeded(
        _ queued: PendingFrame,
        sequence: UInt32
    ) {
        guard queued.source == .redundant else { return }
        metrics.recoveredPackets += 1
        redundantlyOutputSequences.insert(sequence)
        if redundantlyOutputSequences.count > 64,
           let oldest = redundantlyOutputSequences.min() {
            redundantlyOutputSequences.remove(oldest)
        }
    }

    private func concealedFrame() -> Data {
        guard lastOutputFrame.count == Self.bytesPerFrame else {
            return Data(repeating: 0, count: Self.bytesPerFrame)
        }
        var samples = decodedSamples(lastOutputFrame)
        let attenuation = 0.96
        for index in samples.indices {
            let repeated = Double(samples[index]) * attenuation
            if index < Self.fadeSamples {
                let progress = Double(index) / Double(Self.fadeSamples - 1)
                let bridged = Double(lastOutputSample) * (1 - progress)
                    + repeated * progress
                samples[index] = Int16(clamping: Int(bridged.rounded()))
            } else {
                samples[index] = Int16(clamping: Int(repeated.rounded()))
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func fadedIn(_ pcm16: Data) -> Data {
        var samples = decodedSamples(pcm16)
        for index in 0..<min(Self.fadeSamples, samples.count) {
            let progress = Double(index) / Double(Self.fadeSamples - 1)
            let bridged = Double(lastOutputSample) * (1 - progress)
                + Double(samples[index]) * progress
            samples[index] = Int16(clamping: Int(bridged.rounded()))
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

@available(*, deprecated, renamed: "AudioJitterBuffer")
public typealias AudioStreamBuffer = AudioJitterBuffer
