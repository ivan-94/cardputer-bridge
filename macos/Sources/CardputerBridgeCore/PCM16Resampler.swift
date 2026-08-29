import AVFoundation
import Foundation

public enum PCM16ResamplerError: Error, Equatable {
    case formatUnavailable
    case converterUnavailable
    case malformedInput
    case conversionFailed
}

/// Stateful, Core Audio backed 16 kHz PCM16 -> 48 kHz Float32 conversion.
/// A conservative +1.9 dB gain lifts speech without returning to noisy analog gain.
public final class PCM16ToFloat32Resampler {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let outputGain: Float

    public init(outputGain: Float = 1.25) throws {
        guard outputGain > 0,
              let inputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 48_000,
                  channels: 1,
                  interleaved: false
              ) else {
            throw PCM16ResamplerError.formatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PCM16ResamplerError.converterUnavailable
        }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.outputGain = outputGain
    }

    public func convert(_ pcm16LE: Data) throws -> [Float] {
        guard !pcm16LE.isEmpty, pcm16LE.count.isMultiple(of: 2) else {
            throw PCM16ResamplerError.malformedInput
        }
        let inputFrames = pcm16LE.count / 2
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(inputFrames)
        ), let inputChannel = input.int16ChannelData?[0] else {
            throw PCM16ResamplerError.formatUnavailable
        }
        input.frameLength = AVAudioFrameCount(inputFrames)
        pcm16LE.withUnsafeBytes { bytes in
            for frame in 0..<inputFrames {
                let byteIndex = frame * 2
                let bits = UInt16(bytes[byteIndex])
                    | (UInt16(bytes[byteIndex + 1]) << 8)
                inputChannel[frame] = Int16(bitPattern: bits)
            }
        }

        let outputCapacity = AVAudioFrameCount(inputFrames * 3 + 32)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ), let outputChannel = output.floatChannelData?[0] else {
            throw PCM16ResamplerError.formatUnavailable
        }
        var suppliedInput = false
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, status in
            guard !suppliedInput else {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, output.frameLength > 0 else {
            throw PCM16ResamplerError.conversionFailed
        }

        return (0..<Int(output.frameLength)).map { index in
            softLimited(outputChannel[index] * outputGain)
        }
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
