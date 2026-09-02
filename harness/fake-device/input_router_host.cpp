#include "input_router.hpp"

#include <cstdint>
#include <iostream>
#include <optional>
#include <string>

namespace {

constexpr std::uint8_t kUsageQ = 0x14;
constexpr std::uint8_t kLeftControlAndGui = 0x09;

std::optional<std::string> string_field(
    const std::string& line,
    const std::string& key
) {
    const std::string token = "\"" + key + "\"";
    const std::size_t key_position = line.find(token);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }
    const std::size_t colon = line.find(':', key_position + token.size());
    if (colon == std::string::npos) {
        return std::nullopt;
    }
    const std::size_t opening_quote = line.find('"', colon + 1);
    if (opening_quote == std::string::npos) {
        return std::nullopt;
    }
    const std::size_t closing_quote = line.find('"', opening_quote + 1);
    if (closing_quote == std::string::npos) {
        return std::nullopt;
    }
    return line.substr(opening_quote + 1, closing_quote - opening_quote - 1);
}

std::optional<std::uint64_t> integer_field(
    const std::string& line,
    const std::string& key
) {
    const std::string token = "\"" + key + "\"";
    const std::size_t key_position = line.find(token);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }
    const std::size_t colon = line.find(':', key_position + token.size());
    if (colon == std::string::npos) {
        return std::nullopt;
    }
    const std::size_t first_digit = line.find_first_of("0123456789", colon + 1);
    if (first_digit == std::string::npos) {
        return std::nullopt;
    }
    const std::size_t end = line.find_first_not_of("0123456789", first_digit);
    try {
        return std::stoull(line.substr(first_digit, end - first_digit));
    } catch (...) {
        return std::nullopt;
    }
}

const char* action_name(cardbridge::InputActionKind kind) {
    switch (kind) {
        case cardbridge::InputActionKind::kG0Down:
            return "g0_down";
        case cardbridge::InputActionKind::kG0Up:
            return "g0_up";
        case cardbridge::InputActionKind::kG0UpShortcutOnly:
            return "g0_up_shortcut_only";
        case cardbridge::InputActionKind::kKeyDown:
            return "key_down";
        case cardbridge::InputActionKind::kKeyUp:
            return "key_up";
        case cardbridge::InputActionKind::kBleAuthenticated:
            return "ble_authenticated";
        case cardbridge::InputActionKind::kBleDisconnected:
            return "ble_disconnected";
    }
    return "unknown";
}

std::optional<cardbridge::InputActionKind> parse_action(const std::string& value) {
    if (value == "g0_down") return cardbridge::InputActionKind::kG0Down;
    if (value == "g0_up") return cardbridge::InputActionKind::kG0Up;
    if (value == "key_down") return cardbridge::InputActionKind::kKeyDown;
    if (value == "key_up") return cardbridge::InputActionKind::kKeyUp;
    if (value == "ble_authenticated") {
        return cardbridge::InputActionKind::kBleAuthenticated;
    }
    if (value == "ble_disconnected") {
        return cardbridge::InputActionKind::kBleDisconnected;
    }
    return std::nullopt;
}

void emit_error(const std::string& request_id, const char* code) {
    std::cout
        << "{\"v\":1,\"event\":\"error\",\"request_id\":\""
        << request_id << "\",\"code\":\"" << code << "\"}\n";
}

void emit_snapshot(
    const std::string& request_id,
    const cardbridge::InputRouter& router
) {
    std::cout
        << "{\"v\":1,\"event\":\"input_snapshot\",\"request_id\":\""
        << request_id << "\",\"all_keys_up\":"
        << (router.all_keys_up() ? "true" : "false")
        << ",\"g0_active\":" << (router.g0_active() ? "true" : "false")
        << "}\n";
}

void emit_effect(
    const cardbridge::InputEffect& effect,
    const std::string& request_id
) {
    using cardbridge::InputEffectKind;
    switch (effect.kind) {
        case InputEffectKind::kHidReport:
            std::cout
                << "{\"v\":1,\"event\":\"hid_report\",\"request_id\":\""
                << request_id << "\",\"modifiers\":"
                << static_cast<unsigned>(effect.report.modifiers)
                << ",\"usage\":" << static_cast<unsigned>(effect.report.usage)
                << "}\n";
            break;
        case InputEffectKind::kToggleMicIntent:
            std::cout
                << "{\"v\":1,\"event\":\"domain_action\",\"request_id\":\""
                << request_id << "\",\"action\":\"toggle_mic_intent\"}\n";
            break;
        case InputEffectKind::kControlLinkLost:
            std::cout
                << "{\"v\":1,\"event\":\"domain_action\",\"request_id\":\""
                << request_id << "\",\"action\":\"control_link_lost\"}\n";
            break;
        case InputEffectKind::kShortcutFeedback:
            std::cout
                << "{\"v\":1,\"event\":\"shortcut_feedback\",\"request_id\":\""
                << request_id << "\",\"trigger_usage\":"
                << static_cast<unsigned>(effect.trigger_usage)
                << ",\"modifiers\":"
                << static_cast<unsigned>(effect.report.modifiers)
                << ",\"usage\":" << static_cast<unsigned>(effect.report.usage)
                << "}\n";
            break;
        case InputEffectKind::kNotMappedFeedback:
            std::cout
                << "{\"v\":1,\"event\":\"not_mapped\",\"request_id\":\""
                << request_id << "\",\"trigger_usage\":"
                << static_cast<unsigned>(effect.trigger_usage) << "}\n";
            break;
        case InputEffectKind::kShortcutLearned:
            std::cout
                << "{\"v\":1,\"event\":\"shortcut_learned\",\"request_id\":\""
                << request_id << "\",\"token\":" << effect.learn_token
                << ",\"g0\":" << (effect.trigger_includes_g0 ? "true" : "false")
                << ",\"mods\":" << static_cast<unsigned>(effect.trigger_modifiers)
                << ",\"usage\":" << static_cast<unsigned>(effect.trigger_usage)
                << "}\n";
            break;
        case InputEffectKind::kShortcutLearnCancelled:
            std::cout
                << "{\"v\":1,\"event\":\"shortcut_learn_cancelled\",\"request_id\":\""
                << request_id << "\",\"token\":" << effect.learn_token << "}\n";
            break;
    }
}

}  // namespace

int main() {
    cardbridge::InputRouter router;
    bool failed = false;
    const cardbridge::ShortcutMapping default_mapping{
        true,
        0,
        kUsageQ,
        kLeftControlAndGui,
        kUsageQ,
        true,
    };
    if (!router.replace_mappings(&default_mapping, 1)) {
        return 1;
    }

    std::cout
        << "{\"v\":1,\"event\":\"ready\",\"build_id\":\"host-input-v1\","
        << "\"harness\":true}\n";

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;
        const auto command = string_field(line, "command");
        const auto request_id = string_field(line, "request_id");
        if (line.find("\"v\":1") == std::string::npos || !command || !request_id) {
            emit_error(request_id.value_or("unknown"), "command_schema_invalid");
            failed = true;
            continue;
        }

        if (*command == "reset") {
            router.reset();
            emit_snapshot(*request_id, router);
            continue;
        }
        if (*command != "dispatch") {
            emit_error(*request_id, "command_unknown");
            failed = true;
            continue;
        }

        const auto action_text = string_field(line, "action");
        const auto action_kind = action_text ? parse_action(*action_text) : std::nullopt;
        const auto at_ms = integer_field(line, "at_ms");
        if (!action_kind || !at_ms) {
            emit_error(*request_id, "dispatch_schema_invalid");
            failed = true;
            continue;
        }
        const std::uint64_t usage_value = integer_field(line, "usage").value_or(0);
        const std::uint64_t modifier_value = integer_field(line, "modifiers").value_or(0);
        if (usage_value > 255 || modifier_value > 255) {
            emit_error(*request_id, "dispatch_range_invalid");
            failed = true;
            continue;
        }
        const cardbridge::InputAction action{
            *action_kind,
            static_cast<std::uint8_t>(usage_value),
            static_cast<std::uint8_t>(modifier_value),
            *at_ms,
        };
        std::cout
            << "{\"v\":1,\"event\":\"input_action\",\"request_id\":\""
            << *request_id << "\",\"action\":\"" << action_name(*action_kind)
            << "\",\"usage\":" << usage_value
            << ",\"modifiers\":" << modifier_value
            << ",\"at_ms\":" << *at_ms << "}\n";
        const cardbridge::InputResult result = router.dispatch(action);
        for (std::size_t index = 0; index < result.count; ++index) {
            emit_effect(result.effects[index], *request_id);
        }
        emit_snapshot(*request_id, router);
    }

    return failed ? 1 : 0;
}
