#pragma once

#include <cstddef>
#include <cstdint>

namespace cardbridge {

constexpr std::size_t kAudioHeaderBytes = 28;
constexpr std::size_t kAudioFrameSamples = 320;
constexpr std::size_t kAudioPayloadBytes = 640;
constexpr std::size_t kAudioAuthTagBytes = 16;
constexpr std::size_t kAudioNonceBytes = 12;
constexpr std::size_t kAudioDatagramBytes =
    kAudioHeaderBytes + kAudioPayloadBytes + kAudioAuthTagBytes;

enum AudioPacketFlag : std::uint8_t {
    kAudioFlagMuted = 1U << 0,
    kAudioFlagTest = 1U << 1,
    kAudioFlagEnd = 1U << 2,
};

struct AudioPacketHeader {
    std::uint8_t flags = 0;
    std::uint64_t session_id = 0;
    std::uint32_t sequence = 0;
    std::uint32_t capture_sample_index = 0;
    std::uint16_t frame_samples = kAudioFrameSamples;
    std::uint16_t payload_length = kAudioPayloadBytes;

    bool operator==(const AudioPacketHeader& other) const {
        return flags == other.flags &&
            session_id == other.session_id &&
            sequence == other.sequence &&
            capture_sample_index == other.capture_sample_index &&
            frame_samples == other.frame_samples &&
            payload_length == other.payload_length;
    }
};

bool encode_audio_header(
    const AudioPacketHeader& header,
    std::uint8_t* output,
    std::size_t output_size
);

bool decode_audio_header(
    const std::uint8_t* input,
    std::size_t input_size,
    AudioPacketHeader& header
);

void make_audio_nonce(
    std::uint64_t session_id,
    std::uint32_t sequence,
    std::uint8_t output[kAudioNonceBytes]
);

}  // namespace cardbridge
