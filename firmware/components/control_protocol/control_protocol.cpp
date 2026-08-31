#include "control_protocol.hpp"

#include <algorithm>
#include <cstddef>
#include <limits>

namespace cardbridge {
namespace {

bool is_space(char value) {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

std::size_t skip_space(std::string_view value, std::size_t position) {
    while (position < value.size() && is_space(value[position])) {
        ++position;
    }
    return position;
}

std::size_t value_position(std::string_view object, std::string_view key) {
    std::size_t search_from = 0;
    while (search_from < object.size()) {
        const std::size_t quote = object.find('"', search_from);
        if (quote == std::string_view::npos) {
            return std::string_view::npos;
        }
        const std::size_t end_quote = object.find('"', quote + 1);
        if (end_quote == std::string_view::npos) {
            return std::string_view::npos;
        }
        if (object.substr(quote + 1, end_quote - quote - 1) == key) {
            std::size_t colon = skip_space(object, end_quote + 1);
            if (colon < object.size() && object[colon] == ':') {
                return skip_space(object, colon + 1);
            }
        }
        search_from = end_quote + 1;
    }
    return std::string_view::npos;
}

bool string_value_equals(
    std::string_view object,
    std::string_view key,
    std::string_view expected
) {
    const std::size_t position = value_position(object, key);
    if (position == std::string_view::npos || position >= object.size() ||
        object[position] != '"') {
        return false;
    }
    const std::size_t end_quote = object.find('"', position + 1);
    return end_quote != std::string_view::npos &&
        object.substr(position + 1, end_quote - position - 1) == expected;
}

std::string_view string_value(std::string_view object, std::string_view key) {
    const std::size_t position = value_position(object, key);
    if (position == std::string_view::npos || position >= object.size() ||
        object[position] != '"') {
        return {};
    }
    const std::size_t end_quote = object.find('"', position + 1);
    if (end_quote == std::string_view::npos) {
        return {};
    }
    const std::string_view value = object.substr(
        position + 1,
        end_quote - position - 1
    );
    return value.find('\\') == std::string_view::npos ? value : std::string_view{};
}

bool unsigned_value(
    std::string_view object,
    std::string_view key,
    std::uint64_t maximum,
    std::uint64_t& result
) {
    std::size_t position = value_position(object, key);
    if (position == std::string_view::npos || position >= object.size() ||
        object[position] < '0' || object[position] > '9') {
        return false;
    }
    std::uint64_t value = 0;
    while (position < object.size() &&
           object[position] >= '0' && object[position] <= '9') {
        const std::uint8_t digit = static_cast<std::uint8_t>(object[position] - '0');
        if (value > (maximum - digit) / 10) {
            return false;
        }
        value = value * 10 + digit;
        ++position;
    }
    result = value;
    return true;
}

bool optional_bool_value(
    std::string_view object,
    std::string_view key,
    bool default_value
) {
    const std::size_t position = value_position(object, key);
    if (position == std::string_view::npos) return default_value;
    if (object.substr(position, 4) == "true") return true;
    if (object.substr(position, 5) == "false") return false;
    return default_value;
}

int base64_digit(char value) {
    if (value >= 'A' && value <= 'Z') return value - 'A';
    if (value >= 'a' && value <= 'z') return value - 'a' + 26;
    if (value >= '0' && value <= '9') return value - '0' + 52;
    if (value == '+') return 62;
    if (value == '/') return 63;
    return -1;
}

bool decode_base64(
    std::string_view encoded,
    std::uint8_t* output,
    std::size_t output_capacity,
    std::size_t& output_size
) {
    if (encoded.empty() || encoded.size() % 4 != 0 || output == nullptr) {
        return false;
    }
    std::uint32_t accumulator = 0;
    int available_bits = -8;
    output_size = 0;
    bool saw_padding = false;
    for (char value : encoded) {
        if (value == '=') {
            saw_padding = true;
            continue;
        }
        if (saw_padding) {
            return false;
        }
        const int digit = base64_digit(value);
        if (digit < 0) {
            return false;
        }
        accumulator = (accumulator << 6U) | static_cast<std::uint32_t>(digit);
        available_bits += 6;
        if (available_bits >= 0) {
            if (output_size >= output_capacity) {
                return false;
            }
            output[output_size++] = static_cast<std::uint8_t>(
                accumulator >> available_bits
            );
            available_bits -= 8;
        }
    }
    return true;
}

bool parse_hex_u64(std::string_view value, std::uint64_t& result) {
    if (value.size() != 16) {
        return false;
    }
    std::uint64_t parsed = 0;
    for (char character : value) {
        std::uint8_t digit = 0;
        if (character >= '0' && character <= '9') {
            digit = static_cast<std::uint8_t>(character - '0');
        } else if (character >= 'a' && character <= 'f') {
            digit = static_cast<std::uint8_t>(character - 'a' + 10);
        } else if (character >= 'A' && character <= 'F') {
            digit = static_cast<std::uint8_t>(character - 'A' + 10);
        } else {
            return false;
        }
        parsed = (parsed << 4U) | digit;
    }
    result = parsed;
    return parsed != 0;
}

std::string_view object_value(std::string_view parent, std::string_view key) {
    const std::size_t position = value_position(parent, key);
    if (position == std::string_view::npos || position >= parent.size() ||
        parent[position] != '{') {
        return {};
    }

    std::size_t depth = 0;
    bool in_string = false;
    bool escaped = false;
    for (std::size_t index = position; index < parent.size(); ++index) {
        const char current = parent[index];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (current == '\\') {
                escaped = true;
            } else if (current == '"') {
                in_string = false;
            }
            continue;
        }
        if (current == '"') {
            in_string = true;
        } else if (current == '{') {
            ++depth;
        } else if (current == '}') {
            if (--depth == 0) {
                return parent.substr(position, index - position + 1);
            }
        }
    }
    return {};
}

bool is_json_object(std::string_view message) {
    const std::size_t start = skip_space(message, 0);
    if (start >= message.size() || message[start] != '{') {
        return false;
    }
    std::size_t end = message.size();
    while (end > start && is_space(message[end - 1])) {
        --end;
    }
    return end > start && message[end - 1] == '}';
}

bool is_version_one(std::string_view message) {
    const std::size_t version = value_position(message, "v");
    if (version == std::string_view::npos || version >= message.size() ||
        message[version] != '1') {
        return false;
    }
    const std::size_t version_end = skip_space(message, version + 1);
    return version_end < message.size() &&
        (message[version_end] == ',' || message[version_end] == '}');
}

bool is_release_version(std::string_view version) {
    if (version.empty() || version.size() > 23) return false;
    std::size_t component_digits = 0;
    std::size_t dots = 0;
    for (const char value : version) {
        if (value >= '0' && value <= '9') {
            ++component_digits;
            if (component_digits > 3) return false;
        } else if (value == '.' && component_digits > 0 && dots < 2) {
            ++dots;
            component_digits = 0;
        } else {
            return false;
        }
    }
    return dots == 2 && component_digits > 0;
}

bool parse_ipv4_octet(std::string_view value, std::uint8_t& result) {
    if (value.empty() || value.size() > 3 ||
        (value.size() > 1 && value.front() == '0')) {
        return false;
    }
    std::uint16_t parsed = 0;
    for (const char digit : value) {
        if (digit < '0' || digit > '9') return false;
        parsed = static_cast<std::uint16_t>(parsed * 10 + digit - '0');
        if (parsed > 255) return false;
    }
    result = static_cast<std::uint8_t>(parsed);
    return true;
}

bool is_private_ipv4(std::string_view value) {
    std::array<std::uint8_t, 4> octets{};
    std::size_t start = 0;
    for (std::size_t index = 0; index < octets.size(); ++index) {
        const std::size_t dot = value.find('.', start);
        const bool last = index + 1 == octets.size();
        if ((last && dot != std::string_view::npos) ||
            (!last && dot == std::string_view::npos)) {
            return false;
        }
        const std::size_t end = last ? value.size() : dot;
        if (!parse_ipv4_octet(value.substr(start, end - start), octets[index])) {
            return false;
        }
        start = end + 1;
    }
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
}

bool is_lower_hex_token(std::string_view value) {
    if (value.size() != 32) return false;
    return std::all_of(value.begin(), value.end(), [](const char character) {
        return (character >= '0' && character <= '9') ||
            (character >= 'a' && character <= 'f');
    });
}

bool is_trusted_local_relay_url(std::string_view url) {
    constexpr std::string_view scheme = "http://";
    constexpr std::string_view path_prefix = "/cardputer-bridge/";
    constexpr std::string_view suffix = ".bin";
    if (url.substr(0, scheme.size()) != scheme) return false;

    const std::size_t path_start = url.find('/', scheme.size());
    if (path_start == std::string_view::npos) return false;
    const std::string_view authority = url.substr(
        scheme.size(),
        path_start - scheme.size()
    );
    const std::size_t colon = authority.find(':');
    if (colon == std::string_view::npos ||
        authority.find(':', colon + 1) != std::string_view::npos ||
        !is_private_ipv4(authority.substr(0, colon))) {
        return false;
    }
    std::uint64_t port = 0;
    const std::string_view port_text = authority.substr(colon + 1);
    if (port_text.empty() || (port_text.size() > 1 && port_text.front() == '0')) {
        return false;
    }
    for (const char digit : port_text) {
        if (digit < '0' || digit > '9') return false;
        port = port * 10 + static_cast<std::uint64_t>(digit - '0');
        if (port > 65535) return false;
    }
    if (port == 0) return false;

    const std::string_view path = url.substr(path_start);
    if (path.size() != path_prefix.size() + 32 + suffix.size() ||
        path.substr(0, path_prefix.size()) != path_prefix ||
        path.substr(path.size() - suffix.size()) != suffix) {
        return false;
    }
    return is_lower_hex_token(path.substr(path_prefix.size(), 32));
}

bool is_trusted_ota_url(std::string_view url) {
    constexpr std::string_view prefix =
        "https://github.com/ivan-94/cardputer-bridge/releases/";
    constexpr std::string_view suffix = ".bin";
    if (url.size() >= 128 || url.find_first_of("\\?#%") != std::string_view::npos) {
        return false;
    }
    const bool trusted_github = url.size() > prefix.size() + suffix.size() &&
        url.substr(0, prefix.size()) == prefix &&
        url.substr(url.size() - suffix.size()) == suffix;
    return trusted_github || is_trusted_local_relay_url(url);
}

}  // namespace

RemoteMicIntentRequest parse_set_mic_intent(std::string_view message) {
    if (!is_json_object(message)) {
        return RemoteMicIntentRequest::kInvalid;
    }

    if (!is_version_one(message)) {
        return RemoteMicIntentRequest::kInvalid;
    }
    if (!string_value_equals(message, "type", "set_mic_intent")) {
        return RemoteMicIntentRequest::kInvalid;
    }

    const std::string_view body = object_value(message, "body");
    if (body.empty()) {
        return RemoteMicIntentRequest::kInvalid;
    }
    if (string_value_equals(body, "intent", "live")) {
        return RemoteMicIntentRequest::kLive;
    }
    if (string_value_equals(body, "intent", "muted")) {
        return RemoteMicIntentRequest::kMuted;
    }
    return RemoteMicIntentRequest::kInvalid;
}

bool is_heartbeat(std::string_view message) {
    return is_json_object(message)
        && is_version_one(message)
        && string_value_equals(message, "type", "heartbeat");
}

bool parse_shortcut_learn_request(
    std::string_view message,
    ShortcutLearnRequest& request
) {
    if (!is_json_object(message) || !is_version_one(message)) {
        return false;
    }
    std::uint64_t token = 0;
    if (!unsigned_value(message, "token", 0xffffffffU, token) || token == 0) {
        return false;
    }
    ShortcutLearnRequest parsed{};
    if (string_value_equals(message, "type", "shortcut_learn_start")) {
        parsed.kind = ShortcutLearnRequestKind::kStart;
    } else if (string_value_equals(message, "type", "shortcut_learn_cancel")) {
        parsed.kind = ShortcutLearnRequestKind::kCancel;
    } else {
        return false;
    }
    parsed.token = static_cast<std::uint32_t>(token);
    request = parsed;
    return true;
}

bool parse_staged_base64_value(
    std::string_view message,
    std::string_view expected_type,
    std::uint8_t* output,
    std::size_t output_capacity,
    std::size_t& output_size
) {
    if (!is_json_object(message) || !is_version_one(message) ||
        !string_value_equals(message, "type", expected_type)) {
        return false;
    }
    return decode_base64(
        string_value(message, "value"),
        output,
        output_capacity,
        output_size
    );
}

bool is_wifi_commit(std::string_view message) {
    return is_json_object(message) && is_version_one(message) &&
        string_value_equals(message, "type", "wifi_commit");
}

bool parse_audio_offer(std::string_view message, AudioOffer& offer) {
    if (!is_json_object(message) || !is_version_one(message) ||
        !string_value_equals(message, "type", "audio_offer")) {
        return false;
    }
    const std::string_view ipv4 = string_value(message, "ip");
    const std::string_view key = string_value(message, "key");
    const std::string_view session = string_value(message, "sid");
    std::uint64_t port = 0;
    AudioOffer parsed{};
    std::size_t key_size = 0;
    if (ipv4.empty() || ipv4.size() >= parsed.ipv4.size() ||
        !unsigned_value(message, "port", 65535, port) || port == 0 ||
        !parse_hex_u64(session, parsed.session_id) ||
        !decode_base64(key, parsed.key.data(), parsed.key.size(), key_size) ||
        key_size != parsed.key.size()) {
        return false;
    }
    std::copy(ipv4.begin(), ipv4.end(), parsed.ipv4.begin());
    parsed.ipv4[ipv4.size()] = '\0';
    parsed.port = static_cast<std::uint16_t>(port);
    offer = parsed;
    return true;
}

bool parse_audio_ready(std::string_view message, std::uint64_t& session_id) {
    if (!is_json_object(message) || !is_version_one(message) ||
        !string_value_equals(message, "type", "audio_ready")) {
        return false;
    }
    return parse_hex_u64(string_value(message, "sid"), session_id);
}

bool parse_config_prepare(std::string_view message, ConfigPrepare& prepare) {
    if (!is_json_object(message) || !is_version_one(message) ||
        !string_value_equals(message, "type", "config_prepare")) {
        return false;
    }
    std::uint64_t total_bytes = 0;
    std::uint64_t chunk_count = 0;
    ConfigPrepare parsed{};
    std::size_t hash_size = 0;
    if (!parse_hex_u64(string_value(message, "ver"), parsed.version) ||
        !unsigned_value(message, "bytes", 1408, total_bytes) ||
        total_bytes < 12 ||
        !unsigned_value(message, "chunks", 32, chunk_count) ||
        chunk_count == 0 ||
        !decode_base64(
            string_value(message, "sha"),
            parsed.sha256.data(),
            parsed.sha256.size(),
            hash_size
        ) || hash_size != parsed.sha256.size()) {
        return false;
    }
    parsed.total_bytes = static_cast<std::size_t>(total_bytes);
    parsed.chunk_count = static_cast<std::size_t>(chunk_count);
    prepare = parsed;
    return true;
}

bool parse_config_chunk(std::string_view message, ConfigChunk& chunk) {
    if (!is_json_object(message) || !is_version_one(message) ||
        !string_value_equals(message, "type", "config_chunk")) {
        return false;
    }
    std::uint64_t index = 0;
    std::uint64_t offset = 0;
    ConfigChunk parsed{};
    if (!unsigned_value(message, "i", 31, index) ||
        !unsigned_value(message, "off", 1407, offset) ||
        !decode_base64(
            string_value(message, "data"),
            parsed.bytes.data(),
            parsed.bytes.size(),
            parsed.size
        ) || parsed.size == 0) {
        return false;
    }
    parsed.index = static_cast<std::size_t>(index);
    parsed.offset = static_cast<std::size_t>(offset);
    chunk = parsed;
    return true;
}

bool is_config_commit(std::string_view message) {
    return is_json_object(message) && is_version_one(message) &&
        string_value_equals(message, "type", "config_commit");
}

bool parse_ota_start(std::string_view message, OTAStart& request) {
    if (!is_json_object(message) || !is_version_one(message) ||
        !string_value_equals(message, "type", "ota_start")) {
        return false;
    }
    const auto version = string_value(message, "ver");
    const auto url = string_value(message, "url");
    if (!is_release_version(version) || !is_trusted_ota_url(url)) {
        return false;
    }
    OTAStart parsed{};
    std::copy(version.begin(), version.end(), parsed.version.begin());
    std::copy(url.begin(), url.end(), parsed.url.begin());
    parsed.usb_power_verified = optional_bool_value(message, "usb", false);
    request = parsed;
    return true;
}

}  // namespace cardbridge
