#include "audio_packet.hpp"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

void test_network_header_round_trip_matches_protocol_v2() {
    constexpr cardbridge::AudioPacketHeader header{
        0x03,
        0x0102030405060708ULL,
        0x0a0b0c0d,
        0x10111213,
        320,
        640,
    };
    constexpr std::array<std::uint8_t, cardbridge::kAudioHeaderBytes> expected{
        'C', 'B', 'P', '2',
        0x02, 0x03, 0x00, 0x1c,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x0a, 0x0b, 0x0c, 0x0d,
        0x10, 0x11, 0x12, 0x13,
        0x01, 0x40,
        0x02, 0x80,
    };

    std::array<std::uint8_t, cardbridge::kAudioHeaderBytes> encoded{};
    require(
        cardbridge::encode_audio_header(header, encoded.data(), encoded.size()),
        "valid header should encode"
    );
    require(encoded == expected, "header must use the documented network byte order");

    cardbridge::AudioPacketHeader decoded{};
    require(
        cardbridge::decode_audio_header(encoded.data(), encoded.size(), decoded),
        "valid header should decode"
    );
    require(decoded == header, "decoded header should equal input");
}

void test_rejects_wrong_magic_and_non_v2_frame_shape() {
    std::array<std::uint8_t, cardbridge::kAudioHeaderBytes> bytes{
        'X', 'B', 'P', '2',
        0x02, 0x00, 0x00, 0x1c,
        0, 0, 0, 0, 0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 0,
        0x01, 0x40,
        0x02, 0x80,
    };
    cardbridge::AudioPacketHeader decoded{};
    require(
        !cardbridge::decode_audio_header(bytes.data(), bytes.size(), decoded),
        "wrong magic must be rejected"
    );

    bytes[0] = 'C';
    bytes[4] = 1;
    require(!cardbridge::decode_audio_header(bytes.data(), bytes.size(), decoded),
        "legacy encrypted protocol version must be rejected");
    bytes[4] = 2;
    bytes[24] = 0;
    bytes[25] = 1;
    require(
        !cardbridge::decode_audio_header(bytes.data(), bytes.size(), decoded),
        "stream v2 must reject a frame that is not 320 samples"
    );
}

void test_redundancy_interleaves_capture_frames_across_wifi_bursts() {
    require(
        cardbridge::audio_frames_match_redundancy_lag(40, 12'800, 45, 14'400),
        "the delayed copy should span the configured five-frame burst window"
    );
    require(
        !cardbridge::audio_frames_match_redundancy_lag(40, 12'800, 44, 14'080),
        "a frame from the wrong history slot must not enter the datagram"
    );
}

}  // namespace

int main() {
    require(cardbridge::kAudioStreamFrameBytes == 668,
        "plaintext audio must contain only the header and PCM, without a tag");
    std::array<std::int16_t, cardbridge::kAudioFrameSamples> samples{};
    samples[0] = -32768;
    samples[1] = 32767;
    samples[2] = -1;
    std::array<std::uint8_t, cardbridge::kAudioStreamFrameBytes> packet{};
    require(cardbridge::encode_audio_packet({}, samples.data(), packet.data(), packet.size()),
        "PCM packet should encode without a key");
    require(packet[28] == 0 && packet[29] == 0x80 &&
        packet[30] == 0xff && packet[31] == 0x7f &&
        packet[32] == 0xff && packet[33] == 0xff,
        "signed PCM must remain plaintext little-endian");
    require(!cardbridge::encode_audio_packet({}, nullptr, packet.data(), packet.size()),
        "null samples rejected");
    require(!cardbridge::encode_audio_packet({}, samples.data(), packet.data(), packet.size()-1),
        "short output rejected");
    test_network_header_round_trip_matches_protocol_v2();
    test_rejects_wrong_magic_and_non_v2_frame_shape();
    test_redundancy_interleaves_capture_frames_across_wifi_bursts();
    std::cout << "PASS audio_packet_network_order_round_trip\n";
    std::cout << "PASS audio_packet_rejects_invalid_v2_header\n";
    std::cout << "PASS audio_packet_redundancy_interleaves_wifi_bursts\n";
    return EXIT_SUCCESS;
}
