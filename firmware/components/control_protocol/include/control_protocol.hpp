#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace cardbridge {

enum class RemoteMicIntentRequest {
    kInvalid,
    kMuted,
    kLive,
};

RemoteMicIntentRequest parse_set_mic_intent(std::string_view message);
bool is_heartbeat(std::string_view message);

enum class ShortcutLearnRequestKind {
    kInvalid,
    kStart,
    kCancel,
};

struct ShortcutLearnRequest {
    ShortcutLearnRequestKind kind{ShortcutLearnRequestKind::kInvalid};
    std::uint32_t token{0};
};

bool parse_shortcut_learn_request(
    std::string_view message,
    ShortcutLearnRequest& request
);

struct AudioOffer {
    std::array<char, 16> ipv4{};
    std::uint16_t port = 0;
    std::uint64_t session_id = 0;
    std::array<std::uint8_t, 32> key{};
};

struct ConfigPrepare {
    std::uint64_t version = 0;
    std::size_t total_bytes = 0;
    std::size_t chunk_count = 0;
    std::array<std::uint8_t, 32> sha256{};
};

struct ConfigChunk {
    std::size_t index = 0;
    std::size_t offset = 0;
    std::array<std::uint8_t, 72> bytes{};
    std::size_t size = 0;
};

struct OTAStart {
    std::array<char, 24> version{};
    std::array<char, 128> url{};
};

bool parse_staged_base64_value(
    std::string_view message,
    std::string_view expected_type,
    std::uint8_t* output,
    std::size_t output_capacity,
    std::size_t& output_size
);
bool is_wifi_commit(std::string_view message);
bool parse_audio_offer(std::string_view message, AudioOffer& offer);
bool parse_audio_ready(std::string_view message, std::uint64_t& session_id);
bool parse_config_prepare(std::string_view message, ConfigPrepare& prepare);
bool parse_config_chunk(std::string_view message, ConfigChunk& chunk);
bool is_config_commit(std::string_view message);
bool parse_ota_start(std::string_view message, OTAStart& request);

}  // namespace cardbridge
