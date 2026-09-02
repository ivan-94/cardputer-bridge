#pragma once

namespace cardbridge {

enum class MicIntent {
    kMuted,
    kLive,
};

enum class CaptureGate {
    kClosed,
    kOpen,
};

enum class ResetProfile {
    kBootUnpaired,
    kPairedNoWifi,
    kReadyMuted,
};

enum class BridgeAction {
    kToggleMicIntent,
    kMuteMicIntent,
    kControlLinkAuthenticated,
    kControlLinkLost,
    kWifiAudioAuthenticated,
    kWifiAudioLost,
    kAudioSinkReady,
    kAudioSinkLost,
};

enum class ActionSource {
    kHarness,
    kBleControl,
    kPhysicalInput,
};

struct BridgeState {
    MicIntent mic_intent{MicIntent::kMuted};
    CaptureGate capture_gate{CaptureGate::kClosed};
    bool ble_control_authenticated{false};
    bool wifi_audio_authenticated{false};
    bool virtual_mic_ready{false};
};

struct BridgeEvent {
    BridgeAction action{BridgeAction::kToggleMicIntent};
    ActionSource source{ActionSource::kHarness};
};

struct DispatchResult {
    BridgeState state;
    BridgeEvent event;
};

class BridgeDomain {
public:
    void reset(ResetProfile profile);
    DispatchResult dispatch(BridgeAction action, ActionSource source);
    const BridgeState& state() const { return state_; }

private:
    void update_capture_gate();

    BridgeState state_{};
};

}  // namespace cardbridge
