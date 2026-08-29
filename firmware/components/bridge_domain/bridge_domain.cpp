#include "bridge_domain.hpp"

namespace cardbridge {

void BridgeDomain::reset(ResetProfile profile) {
    switch (profile) {
        case ResetProfile::kBootUnpaired:
            state_ = BridgeState{
                MicIntent::kMuted,
                CaptureGate::kClosed,
                false,
                false,
                false,
            };
            break;
        case ResetProfile::kPairedNoWifi:
            state_ = BridgeState{
                MicIntent::kMuted,
                CaptureGate::kClosed,
                true,
                false,
                true,
            };
            break;
        case ResetProfile::kReadyMuted:
            state_ = BridgeState{
                MicIntent::kMuted,
                CaptureGate::kClosed,
                true,
                true,
                true,
            };
            break;
    }
}

DispatchResult BridgeDomain::dispatch(BridgeAction action, ActionSource source) {
    switch (action) {
        case BridgeAction::kToggleMicIntent:
            state_.mic_intent = state_.mic_intent == MicIntent::kMuted
                ? MicIntent::kLive
                : MicIntent::kMuted;
            break;
        case BridgeAction::kControlLinkAuthenticated:
            state_.ble_control_authenticated = true;
            break;
        case BridgeAction::kControlLinkLost:
            state_.ble_control_authenticated = false;
            state_.mic_intent = MicIntent::kMuted;
            break;
        case BridgeAction::kWifiAudioAuthenticated:
            state_.wifi_audio_authenticated = true;
            break;
        case BridgeAction::kWifiAudioLost:
            state_.wifi_audio_authenticated = false;
            state_.mic_intent = MicIntent::kMuted;
            break;
        case BridgeAction::kAudioSinkReady:
            state_.virtual_mic_ready = true;
            break;
        case BridgeAction::kAudioSinkLost:
            state_.virtual_mic_ready = false;
            state_.mic_intent = MicIntent::kMuted;
            break;
    }

    update_capture_gate();
    return DispatchResult{state_, BridgeEvent{action, source}};
}

void BridgeDomain::update_capture_gate() {
    const bool authorized = state_.mic_intent == MicIntent::kLive
        && state_.ble_control_authenticated
        && state_.wifi_audio_authenticated
        && state_.virtual_mic_ready;
    state_.capture_gate = authorized ? CaptureGate::kOpen : CaptureGate::kClosed;
}

}  // namespace cardbridge
