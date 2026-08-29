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
    require(domain.state().mic_intent == cardbridge::MicIntent::kMuted,
            "Wi-Fi loss must fail closed to muted");

    std::cout << "PASS bridge_domain_boot_unpaired_then_authenticated\n";
    std::cout << "PASS bridge_domain_fail_closed_without_links\n";
    std::cout << "PASS bridge_domain_opens_when_authorized\n";
    std::cout << "PASS bridge_domain_control_loss_fails_closed\n";
    std::cout << "PASS bridge_domain_wifi_audio_loss_fails_closed\n";
    return EXIT_SUCCESS;
}
