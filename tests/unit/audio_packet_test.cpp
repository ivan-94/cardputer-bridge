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

void test_network_header_round_trip_matches_protocol_v1() {
    constexpr cardbridge::AudioPacketHeader header{
        0x03,
        0x0102030405060708ULL,
        0x0a0b0c0d,
        0x10111213,
        160,
        320,
    };
    constexpr std::array<std::uint8_t, cardbridge::kAudioHeaderBytes> expected{
        'C', 'B', 'S', '1',
        0x01, 0x03, 0x00, 0x1c,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x0a, 0x0b, 0x0c, 0x0d,
        0x10, 0x11, 0x12, 0x13,
        0x00, 0xa0,
        0x01, 0x40,
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

void test_rejects_wrong_magic_and_non_v1_frame_shape() {
    std::array<std::uint8_t, cardbridge::kAudioHeaderBytes> bytes{
        'X', 'B', 'S', '1',
        0x01, 0x00, 0x00, 0x1c,
        0, 0, 0, 0, 0, 0, 0, 1,
        0, 0, 0, 1,
        0, 0, 0, 0,
        0x00, 0xa0,
        0x01, 0x40,
    };
    cardbridge::AudioPacketHeader decoded{};
    require(
        !cardbridge::decode_audio_header(bytes.data(), bytes.size(), decoded),
        "wrong magic must be rejected"
    );

    bytes[0] = 'C';
    bytes[24] = 0;
    bytes[25] = 1;
    require(
        !cardbridge::decode_audio_header(bytes.data(), bytes.size(), decoded),
        "stream v1 must reject a frame that is not 160 samples"
    );
}

}  // namespace

int main() {
    test_network_header_round_trip_matches_protocol_v1();
    test_rejects_wrong_magic_and_non_v1_frame_shape();
    std::cout << "PASS audio_packet_network_order_round_trip\n";
    std::cout << "PASS audio_packet_rejects_invalid_v1_header\n";
    return EXIT_SUCCESS;
}
