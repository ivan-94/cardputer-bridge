#include "bridge_domain.hpp"

#include <cstdlib>
#include <iostream>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(EXIT_FAILURE);
    }
}

}  // namespace

int main() {
    cardbridge::BridgeDomain domain;

    domain.reset(cardbridge::ResetProfile::kBootUnpaired);
    require(!domain.state().ble_control_authenticated,
            "boot must not claim an authenticated BLE control link");
    const auto paired_result = domain.dispatch(
        cardbridge::BridgeAction::kControlLinkAuthenticated,
        cardbridge::ActionSource::kBleControl
    );
    require(paired_result.state.ble_control_authenticated,
            "successful secure pairing should authenticate the control link");
    require(paired_result.state.capture_gate == cardbridge::CaptureGate::kClosed,
            "BLE authentication alone must not open audio capture");

    domain.reset(cardbridge::ResetProfile::kPairedNoWifi);
    const auto result = domain.dispatch(
        cardbridge::BridgeAction::kToggleMicIntent,
        cardbridge::ActionSource::kHarness
    );

    require(result.state.mic_intent == cardbridge::MicIntent::kLive,
            "G0 short press should record the user's live intent");
    require(result.state.capture_gate == cardbridge::CaptureGate::kClosed,
            "capture must stay closed while authenticated links are unavailable");
    require(result.event.source == cardbridge::ActionSource::kHarness,
            "the event should preserve the action source");

    domain.reset(cardbridge::ResetProfile::kReadyMuted);
    const auto authorized_result = domain.dispatch(
        cardbridge::BridgeAction::kToggleMicIntent,
        cardbridge::ActionSource::kHarness
    );

    require(authorized_result.state.mic_intent == cardbridge::MicIntent::kLive,
            "an authenticated ready device should record live intent");
    require(authorized_result.state.capture_gate == cardbridge::CaptureGate::kOpen,
            "capture should open only when every authorization input is ready");

    const auto physical_key_result = domain.dispatch(
        cardbridge::BridgeAction::kMuteMicIntent,
        cardbridge::ActionSource::kPhysicalInput
    );
    require(physical_key_result.state.mic_intent == cardbridge::MicIntent::kMuted,
            "any physical key should mute an active microphone");
    require(physical_key_result.state.capture_gate == cardbridge::CaptureGate::kClosed,
            "a physical-key mute must close capture immediately");
    require(physical_key_result.event.source == cardbridge::ActionSource::kPhysicalInput,
            "the mute event should preserve the physical input source");

    const auto repeated_physical_key_result = domain.dispatch(
        cardbridge::BridgeAction::kMuteMicIntent,
        cardbridge::ActionSource::kPhysicalInput
    );
    require(repeated_physical_key_result.state.mic_intent == cardbridge::MicIntent::kMuted,
            "physical-key mute must be idempotent and never reopen the microphone");

    const auto disconnected_result = domain.dispatch(
        cardbridge::BridgeAction::kControlLinkLost,
        cardbridge::ActionSource::kBleControl
    );

    require(disconnected_result.state.mic_intent == cardbridge::MicIntent::kMuted,
            "losing the authenticated control link must clear live intent");
    require(disconnected_result.state.capture_gate == cardbridge::CaptureGate::kClosed,
            "losing the authenticated control link must close capture");
    require(!disconnected_result.state.ble_control_authenticated,
            "the state should expose that the control link is unavailable");

    domain.reset(cardbridge::ResetProfile::kPairedNoWifi);
    domain.dispatch(
        cardbridge::BridgeAction::kToggleMicIntent,
        cardbridge::ActionSource::kHarness
    );
    domain.dispatch(
        cardbridge::BridgeAction::kWifiAudioAuthenticated,
        cardbridge::ActionSource::kBleControl
    );
    require(domain.state().capture_gate == cardbridge::CaptureGate::kOpen,
            "capture should open when Wi-Fi audio joins the paired ready sink");
    domain.dispatch(
        cardbridge::BridgeAction::kWifiAudioLost,
        cardbridge::ActionSource::kBleControl
    );
    require(domain.state().capture_gate == cardbridge::CaptureGate::kClosed,
            "Wi-Fi loss must close capture");
    require(domain.state().mic_intent == cardbridge::MicIntent::kLive,
            "transient Wi-Fi loss must preserve the user's live intent");
    domain.dispatch(
        cardbridge::BridgeAction::kWifiAudioAuthenticated,
        cardbridge::ActionSource::kBleControl
    );
    require(domain.state().capture_gate == cardbridge::CaptureGate::kOpen,
            "capture should resume when Wi-Fi recovers and live intent remains");

    domain.dispatch(
        cardbridge::BridgeAction::kAudioSinkLost,
        cardbridge::ActionSource::kBleControl
    );
    require(domain.state().capture_gate == cardbridge::CaptureGate::kClosed,
            "audio-sink loss must close capture");
    require(domain.state().mic_intent == cardbridge::MicIntent::kLive,
            "transient audio-sink loss must preserve the user's live intent");
    domain.dispatch(
        cardbridge::BridgeAction::kMuteMicIntent,
        cardbridge::ActionSource::kPhysicalInput
    );
    require(domain.state().mic_intent == cardbridge::MicIntent::kMuted,
            "a physical key during an outage must cancel the user's live intent");
    domain.dispatch(
        cardbridge::BridgeAction::kAudioSinkReady,
        cardbridge::ActionSource::kBleControl
    );
    require(domain.state().capture_gate == cardbridge::CaptureGate::kClosed,
            "capture must stay closed after the user cancels during an outage");

    std::cout << "PASS bridge_domain_boot_unpaired_then_authenticated\n";
    std::cout << "PASS bridge_domain_fail_closed_without_links\n";
    std::cout << "PASS bridge_domain_opens_when_authorized\n";
    std::cout << "PASS bridge_domain_physical_key_mute_is_idempotent\n";
    std::cout << "PASS bridge_domain_control_loss_fails_closed\n";
    std::cout << "PASS bridge_domain_transient_audio_links_preserve_live_intent\n";
    return EXIT_SUCCESS;
}
