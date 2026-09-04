import Foundation

public enum PCM16ResamplerError: Error, Equatable {
    case formatUnavailable
    case converterUnavailable
    case malformedInput
    case conversionFailed
}

/// Stateful 16 kHz PCM16 -> 48 kHz Float32 conversion.
///
/// The ratio is exactly 3:1, so a general-purpose audio converter adds avoidable
/// setup, allocation and scheduling cost to every 20 ms network frame. Linear
/// interpolation keeps the clock exact and the receive queue comfortably ahead
/// of real time, including unoptimised local acceptance builds.
public final class PCM16ToFloat32Resampler {
    private let outputGain: Float
    private var previousSample: Float?

    public init(outputGain: Float = 1.25) throws {
        guard outputGain > 0 else {
            throw PCM16ResamplerError.formatUnavailable
        }
        self.outputGain = outputGain
    }

    public func convert(_ pcm16LE: Data) throws -> [Float] {
        guard !pcm16LE.isEmpty, pcm16LE.count.isMultiple(of: 2) else {
            throw PCM16ResamplerError.malformedInput
        }
        let inputFrames = pcm16LE.count / 2
        var output = [Float](repeating: 0, count: inputFrames * 3)
        pcm16LE.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            var previous = previousSample
            for frame in 0..<inputFrames {
                let byteIndex = frame * 2
                let bits = UInt16(bytes[byteIndex])
                    | (UInt16(bytes[byteIndex + 1]) << 8)
                let current = Float(Int16(bitPattern: bits)) / 32_768
                let start = previous ?? current
                let delta = current - start
                let outputIndex = frame * 3
                output[outputIndex] = softLimited(
                    (start + delta / 3) * outputGain
                )
                output[outputIndex + 1] = softLimited(
                    (start + delta * 2 / 3) * outputGain
                )
                output[outputIndex + 2] = softLimited(current * outputGain)
                previous = current
            }
            previousSample = previous
        }
        return output
    }

    private func softLimited(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        let threshold: Float = 0.85
        guard magnitude > threshold else { return sample }
        let headroom = 1 - threshold
        let normalized = (magnitude - threshold) / headroom
        let compressed = threshold + headroom * normalized / (1 + normalized)
        return sample.sign == .minus ? -compressed : compressed
    }
}
