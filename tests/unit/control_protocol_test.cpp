#include "control_protocol.hpp"

#include <cstdlib>
#include <cstring>
#include <string_view>

namespace {

bool expect(
    std::string_view message,
    cardbridge::RemoteMicIntentRequest expected
) {
    return cardbridge::parse_set_mic_intent(message) == expected;
}

}  // namespace

int main() {
    if (!expect(
        R"({"v":1,"id":"request-1","type":"set_mic_intent","sent_at_ms":123,"body":{"intent":"live"}})",
        cardbridge::RemoteMicIntentRequest::kLive)) {
        return EXIT_FAILURE;
    }
    if (!expect(
        R"({ "body": { "intent": "muted" }, "type": "set_mic_intent", "v": 1 })",
        cardbridge::RemoteMicIntentRequest::kMuted)) {
        return EXIT_FAILURE;
    }
    if (!expect("toggle_mic", cardbridge::RemoteMicIntentRequest::kInvalid)) {
        return EXIT_FAILURE;
    }
    if (!expect(
        R"({"v":2,"type":"set_mic_intent","body":{"intent":"live"}})",
        cardbridge::RemoteMicIntentRequest::kInvalid)) {
        return EXIT_FAILURE;
    }
    if (!expect(
        R"({"v":1,"type":"set_mic_intent","intent":"live","body":{}})",
        cardbridge::RemoteMicIntentRequest::kInvalid)) {
        return EXIT_FAILURE;
    }
    if (!cardbridge::is_heartbeat(
        R"({"v":1,"id":"heartbeat-1","type":"heartbeat","sent_at_ms":123,"body":{"intent":"live"}})")) {
        return EXIT_FAILURE;
    }
    if (cardbridge::is_heartbeat(
        R"({"v":2,"id":"heartbeat-2","type":"heartbeat","body":{}})")) {
        return EXIT_FAILURE;
    }

    cardbridge::ShortcutLearnRequest learn{};
    if (!cardbridge::parse_shortcut_learn_request(
            R"({"v":1,"type":"shortcut_learn_start","token":305419896})",
            learn) ||
        learn.kind != cardbridge::ShortcutLearnRequestKind::kStart ||
        learn.token != 0x12345678U) {
        return EXIT_FAILURE;
    }
    if (!cardbridge::parse_shortcut_learn_request(
            R"({"v":1,"type":"shortcut_learn_cancel","token":305419896})",
            learn) ||
        learn.kind != cardbridge::ShortcutLearnRequestKind::kCancel ||
        learn.token != 0x12345678U ||
        cardbridge::parse_shortcut_learn_request(
            R"({"v":1,"type":"shortcut_learn_start","token":0})",
            learn)) {
        return EXIT_FAILURE;
    }

    std::uint8_t decoded[64]{};
    std::size_t decoded_size = 0;
    if (!cardbridge::parse_staged_base64_value(
            R"({"v":1,"type":"wifi_stage_ssid","value":"Q2FyZHB1dGVy"})",
            "wifi_stage_ssid",
            decoded,
            sizeof(decoded),
            decoded_size) ||
        decoded_size != 9 ||
        std::memcmp(decoded, "Cardputer", 9) != 0) {
        return EXIT_FAILURE;
    }
    if (!cardbridge::is_wifi_commit(
            R"({"v":1,"type":"wifi_commit"})")) {
        return EXIT_FAILURE;
    }

    cardbridge::AudioOffer offer{};
    if (!cardbridge::parse_audio_offer(
            R"({"v":1,"type":"audio_offer","ip":"192.168.2.109","port":54321,"sid":"0102030405060708","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="})",
            offer) ||
        std::string_view(offer.ipv4.data()) != "192.168.2.109" ||
        offer.port != 54321 ||
        offer.session_id != 0x0102030405060708ULL ||
        offer.key[0] != 0 || offer.key[31] != 31) {
        return EXIT_FAILURE;
    }
    std::uint64_t ready_session = 0;
    if (!cardbridge::parse_audio_ready(
            R"({"v":1,"type":"audio_ready","sid":"0102030405060708"})",
            ready_session) ||
        ready_session != 0x0102030405060708ULL) {
        return EXIT_FAILURE;
    }
    cardbridge::ConfigPrepare prepare{};
    if (!cardbridge::parse_config_prepare(
            R"({"v":1,"type":"config_prepare","ver":"0000000000000007","bytes":24,"chunks":2,"sha":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="})",
            prepare) ||
        prepare.version != 7 || prepare.total_bytes != 24 ||
        prepare.chunk_count != 2 || prepare.sha256[31] != 31) {
        return EXIT_FAILURE;
    }
    cardbridge::ConfigChunk chunk{};
    if (!cardbridge::parse_config_chunk(
            R"({"v":1,"type":"config_chunk","i":1,"off":12,"data":"Q0JyaWRnZQ=="})",
            chunk) ||
        chunk.index != 1 || chunk.offset != 12 || chunk.size != 7 ||
        std::memcmp(chunk.bytes.data(), "CBridge", 7) != 0 ||
        !cardbridge::is_config_commit(
            R"({"v":1,"type":"config_commit"})")) {
        return EXIT_FAILURE;
    }
    cardbridge::OTAStart ota{};
    if (!cardbridge::parse_ota_start(
            R"({"v":1,"type":"ota_start","ver":"0.10.0","url":"https://github.com/ivan-94/cardputer-bridge/releases/latest/download/cardputer_bridge_firmware.bin"})",
            ota) ||
        std::string_view(ota.version.data()) != "0.10.0" ||
        std::string_view(ota.url.data()).find("https://github.com/ivan-94/") != 0 ||
        cardbridge::parse_ota_start(
            R"({"v":1,"type":"ota_start","ver":"0.10.0","url":"http://192.168.2.1/firmware.bin"})",
            ota)) {
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
