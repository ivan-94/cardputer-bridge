import Foundation

public struct AudioStreamMetrics: Equatable, Sendable {
    public var acceptedPackets = 0
    public var missingPackets = 0
    public var duplicateOrLatePackets = 0
    public var lastSequence: UInt32?
    public var signalLevel = 0.0

    public init() {}
}

public struct AudioFrameAccumulator: Sendable {
    public let sessionID: UInt64
    public private(set) var metrics = AudioStreamMetrics()
    private var expectedSequence: UInt32?

    public init(sessionID: UInt64) {
        self.sessionID = sessionID
    }

    @discardableResult
    public mutating func accept(_ frame: AudioFrameV1) -> Bool {
        guard frame.sessionID == sessionID else { return false }
        if let expectedSequence {
            guard frame.sequence >= expectedSequence else {
                metrics.duplicateOrLatePackets += 1
                return false
            }
            metrics.missingPackets += Int(frame.sequence - expectedSequence)
        }
        metrics.acceptedPackets += 1
        metrics.lastSequence = frame.sequence
        metrics.signalLevel = signalLevel(frame.pcm16)
        expectedSequence = frame.sequence &+ 1
        return true
    }

    private func signalLevel(_ pcm16: Data) -> Double {
        guard pcm16.count >= 2 else { return 0 }
        var squareSum = 0.0
        var sampleCount = 0
        var index = 0
        while index + 1 < pcm16.count {
            let bits = UInt16(pcm16[index]) | (UInt16(pcm16[index + 1]) << 8)
            let sample = Double(Int16(bitPattern: bits)) / 32_768.0
            squareSum += sample * sample
            sampleCount += 1
            index += 2
        }
        return (squareSum / Double(sampleCount)).squareRoot()
    }
}
