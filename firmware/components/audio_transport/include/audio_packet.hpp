#pragma once

#include <cstddef>
#include <cstdint>

namespace cardbridge {

constexpr std::size_t kAudioHeaderBytes = 28;
constexpr std::size_t kAudioFrameSamples = 320;
constexpr std::size_t kAudioPayloadBytes = 640;
constexpr std::size_t kAudioStreamFrameBytes =
    kAudioHeaderBytes + kAudioPayloadBytes;
constexpr std::size_t kAudioRedundantDatagramBytes =
    kAudioStreamFrameBytes * 2;
constexpr std::uint32_t kAudioRedundancyLagFrames = 5;
static_assert(
    kAudioRedundantDatagramBytes <= 1472,
    "redundant audio datagram must fit an IPv4 MTU without fragmentation"
);

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

constexpr bool audio_frames_match_redundancy_lag(
    std::uint32_t redundant_sequence,
    std::uint32_t redundant_capture_sample_index,
    std::uint32_t current_sequence,
    std::uint32_t current_capture_sample_index
) {
    return redundant_sequence + kAudioRedundancyLagFrames == current_sequence &&
        redundant_capture_sample_index +
            kAudioFrameSamples * kAudioRedundancyLagFrames ==
            current_capture_sample_index;
}

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

// Header uses network byte order; PCM is always signed little-endian.
bool encode_audio_packet(
    const AudioPacketHeader& header,
    const std::int16_t* samples,
    std::uint8_t* output,
    std::size_t output_size
);

}  // namespace cardbridge
