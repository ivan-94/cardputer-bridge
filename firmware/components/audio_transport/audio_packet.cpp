#include "audio_packet.hpp"

#include <algorithm>

namespace cardbridge {
namespace {

constexpr std::uint8_t kMagic[] = {'C', 'B', 'P', '2'};
constexpr std::uint8_t kVersion = 2;

void write_u16(std::uint8_t* output, std::uint16_t value) {
    output[0] = static_cast<std::uint8_t>(value >> 8);
    output[1] = static_cast<std::uint8_t>(value);
}

void write_u32(std::uint8_t* output, std::uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8) {
        *output++ = static_cast<std::uint8_t>(value >> shift);
    }
}

void write_u64(std::uint8_t* output, std::uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        *output++ = static_cast<std::uint8_t>(value >> shift);
    }
}

std::uint16_t read_u16(const std::uint8_t* input) {
    return static_cast<std::uint16_t>(input[0] << 8U) |
        static_cast<std::uint16_t>(input[1]);
}

std::uint32_t read_u32(const std::uint8_t* input) {
    std::uint32_t value = 0;
    for (int index = 0; index < 4; ++index) {
        value = (value << 8U) | input[index];
    }
    return value;
}

std::uint64_t read_u64(const std::uint8_t* input) {
    std::uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value = (value << 8U) | input[index];
    }
    return value;
}

bool valid_frame_shape(const AudioPacketHeader& header) {
    return header.frame_samples == kAudioFrameSamples &&
        header.payload_length == kAudioPayloadBytes;
}

}  // namespace

bool encode_audio_header(
    const AudioPacketHeader& header,
    std::uint8_t* output,
    std::size_t output_size
) {
    if (output == nullptr || output_size < kAudioHeaderBytes ||
        !valid_frame_shape(header)) {
        return false;
    }
    std::copy(kMagic, kMagic + sizeof(kMagic), output);
    output[4] = kVersion;
    output[5] = header.flags;
    write_u16(output + 6, kAudioHeaderBytes);
    write_u64(output + 8, header.session_id);
    write_u32(output + 16, header.sequence);
    write_u32(output + 20, header.capture_sample_index);
    write_u16(output + 24, header.frame_samples);
    write_u16(output + 26, header.payload_length);
    return true;
}

bool decode_audio_header(
    const std::uint8_t* input,
    std::size_t input_size,
    AudioPacketHeader& header
) {
    if (input == nullptr || input_size < kAudioHeaderBytes ||
        !std::equal(kMagic, kMagic + sizeof(kMagic), input) ||
        input[4] != kVersion || read_u16(input + 6) != kAudioHeaderBytes) {
        return false;
    }
    AudioPacketHeader candidate{
        input[5],
        read_u64(input + 8),
        read_u32(input + 16),
        read_u32(input + 20),
        read_u16(input + 24),
        read_u16(input + 26),
    };
    if (!valid_frame_shape(candidate)) {
        return false;
    }
    header = candidate;
    return true;
}

bool encode_audio_packet(
    const AudioPacketHeader& header,
    const std::int16_t* samples,
    std::uint8_t* output,
    std::size_t output_size
) {
    if (samples == nullptr || output_size != kAudioStreamFrameBytes ||
        !encode_audio_header(header, output, output_size)) return false;
    for (std::size_t index = 0; index < kAudioFrameSamples; ++index) {
        const auto sample = static_cast<std::uint16_t>(samples[index]);
        output[kAudioHeaderBytes + index * 2] = static_cast<std::uint8_t>(sample);
        output[kAudioHeaderBytes + index * 2 + 1] = static_cast<std::uint8_t>(sample >> 8);
    }
    return true;
}

}  // namespace cardbridge
