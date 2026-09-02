#include "bridge_domain.hpp"

#include <iostream>
#include <optional>
#include <string>

namespace {

const char* mic_intent_name(cardbridge::MicIntent value) {
    return value == cardbridge::MicIntent::kLive ? "live" : "muted";
}

const char* capture_gate_name(cardbridge::CaptureGate value) {
    return value == cardbridge::CaptureGate::kOpen ? "open" : "closed";
}

const char* action_name(cardbridge::BridgeAction value) {
    switch (value) {
        case cardbridge::BridgeAction::kToggleMicIntent:
            return "toggle_mic_intent";
        case cardbridge::BridgeAction::kMuteMicIntent:
            return "mute_mic_intent";
        case cardbridge::BridgeAction::kControlLinkAuthenticated:
            return "control_link_authenticated";
        case cardbridge::BridgeAction::kControlLinkLost:
            return "control_link_lost";
        case cardbridge::BridgeAction::kWifiAudioAuthenticated:
            return "wifi_audio_authenticated";
        case cardbridge::BridgeAction::kWifiAudioLost:
            return "wifi_audio_lost";
        case cardbridge::BridgeAction::kAudioSinkReady:
            return "audio_sink_ready";
        case cardbridge::BridgeAction::kAudioSinkLost:
            return "audio_sink_lost";
    }
    return "unknown";
}

const char* source_name(cardbridge::ActionSource value) {
    switch (value) {
        case cardbridge::ActionSource::kHarness:
            return "harness";
        case cardbridge::ActionSource::kBleControl:
            return "ble_control";
        case cardbridge::ActionSource::kPhysicalInput:
            return "physical_input";
    }
    return "unknown";
}

void emit_state(const cardbridge::BridgeState& state) {
    std::cout
        << "\"mic_intent\":\"" << mic_intent_name(state.mic_intent)
        << "\",\"capture_gate\":\"" << capture_gate_name(state.capture_gate)
        << "\",\"ble_control_authenticated\":"
        << (state.ble_control_authenticated ? "true" : "false")
        << ",\"wifi_audio_authenticated\":"
        << (state.wifi_audio_authenticated ? "true" : "false")
        << ",\"virtual_mic_ready\":"
        << (state.virtual_mic_ready ? "true" : "false");
}

void emit_transition(
    const cardbridge::DispatchResult& result,
    const std::string& request_id
) {
    const auto& state = result.state;
    const auto& event = result.event;
    std::cout
        << "{\"v\":1,\"event\":\"transition\",\"request_id\":\""
        << request_id
        << "\",\"action\":\""
        << action_name(event.action)
        << "\",\"source\":\""
        << source_name(event.source)
        << "\",";
    emit_state(state);
    std::cout << "}\n";
}

void emit_snapshot(
    const std::string& profile,
    const std::string& request_id,
    const cardbridge::BridgeState& state
) {
    std::cout
        << "{\"v\":1,\"event\":\"snapshot\",\"request_id\":\""
        << request_id
        << "\",\"profile\":\""
        << profile
        << "\",";
    emit_state(state);
    std::cout << "}\n";
}

void emit_error(const std::string& code, const std::string& request_id) {
    std::cout
        << "{\"v\":1,\"event\":\"error\",\"request_id\":\""
        << request_id
        << "\",\"code\":\""
        << code
        << "\"}\n";
}

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
    const std::size_t opening_quote = line.find('"', colon + 1);
    const std::size_t closing_quote = line.find('"', opening_quote + 1);
    if (colon == std::string::npos || opening_quote == std::string::npos
        || closing_quote == std::string::npos) {
        return std::nullopt;
    }
    return line.substr(opening_quote + 1, closing_quote - opening_quote - 1);
}

}  // namespace

int main() {
    cardbridge::BridgeDomain domain;
    bool failed = false;

    std::cout << "{\"v\":1,\"event\":\"ready\",\"build_id\":\"host-domain-v1\",\"harness\":true}\n";

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) {
            continue;
        }
        const auto command = string_field(line, "command");
        const auto request_id = string_field(line, "request_id");
        const bool version_valid = line.find("\"v\":1") != std::string::npos;
        if (!version_valid || !command || !request_id) {
            emit_error("command_schema_invalid", request_id.value_or("unknown"));
            failed = true;
            continue;
        }

        if (*command == "reset") {
            const auto profile = string_field(line, "profile");
            if (profile && *profile == "paired_no_wifi") {
                domain.reset(cardbridge::ResetProfile::kPairedNoWifi);
                emit_snapshot(*profile, *request_id, domain.state());
            } else if (profile && *profile == "ready_muted") {
                domain.reset(cardbridge::ResetProfile::kReadyMuted);
                emit_snapshot(*profile, *request_id, domain.state());
            } else {
                emit_error("reset_profile_unknown", *request_id);
                failed = true;
            }
            continue;
        }

        if (*command == "dispatch") {
            const auto action = string_field(line, "action");
            const auto source = string_field(line, "source");
            if (action && source && *action == "toggle_mic_intent" && *source == "harness") {
                emit_transition(
                    domain.dispatch(
                        cardbridge::BridgeAction::kToggleMicIntent,
                        cardbridge::ActionSource::kHarness),
                    *request_id);
            } else if (action && source && *action == "mute_mic_intent" &&
                       *source == "physical_input") {
                emit_transition(
                    domain.dispatch(
                        cardbridge::BridgeAction::kMuteMicIntent,
                        cardbridge::ActionSource::kPhysicalInput),
                    *request_id);
            } else if (action && source && *action == "control_link_lost" && *source == "ble_control") {
                emit_transition(
                    domain.dispatch(
                        cardbridge::BridgeAction::kControlLinkLost,
                        cardbridge::ActionSource::kBleControl),
                    *request_id);
            } else {
                emit_error("dispatch_unsupported", *request_id);
                failed = true;
            }
            continue;
        }

        emit_error("command_unknown", *request_id);
        failed = true;
    }

    return failed ? 1 : 0;
}
