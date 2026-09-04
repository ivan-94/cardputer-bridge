import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
RECEIVER = (
    PROJECT_ROOT
    / "macos/Sources/CardputerBridgeApp/AudioReceiverController.swift"
)
JITTER_BUFFER = (
    PROJECT_ROOT
    / "macos/Sources/CardputerBridgeCore/AudioStreamBuffer.swift"
)
HIL = PROJECT_ROOT / "scripts/verify_audio_hil.py"
PHASE3 = PROJECT_ROOT / "scripts/verify-phase-3.sh"
SDKCONFIG_DEFAULTS = PROJECT_ROOT / "firmware/sdkconfig.defaults"
DEVICE_AUDIO = (
    PROJECT_ROOT / "firmware/components/device_audio/device_audio.cpp"
)
AUDIO_PACKET = (
    PROJECT_ROOT
    / "firmware/components/audio_transport/include/audio_packet.hpp"
)
FIRMWARE_MAIN = PROJECT_ROOT / "firmware/main/main.cpp"
BLE_CONTROLLER = (
    PROJECT_ROOT / "macos/Sources/CardputerBridgeApp/BLEBridgeController.swift"
)
CONTROL_LEASE = (
    PROJECT_ROOT / "firmware/components/control_lease/control_lease.cpp"
)


class AudioReliabilityContractTests(unittest.TestCase):
    def test_hil_default_proves_a_full_minute_without_gaps(self) -> None:
        hil = HIL.read_text(encoding="utf-8")
        phase3 = PHASE3.read_text(encoding="utf-8")

        self.assertIn(
            'parser.add_argument("--capture-seconds", type=float, default=60.0)',
            hil,
        )
        self.assertIn('CARDPUTER_PHASE3_CAPTURE_SECONDS:-60', phase3)
        self.assertIn("if missing_growth != 0", hil)
        self.assertIn("if duplicate_growth != 0", hil)
        self.assertIn("if stream_failure_growth != 0", hil)
        self.assertIn("system_microphone_not_ready", hil)
        self.assertIn("system_microphone_received_no_audio", hil)
        self.assertIn("if capture_overrun_growth != 0", hil)
        self.assertIn("wait_for_receiver_drain", hil)
        self.assertIn("quiet_seconds", hil)
        self.assertIn("wait_for_device_counter_refresh", hil)
        self.assertIn("ensure_microphone_muted", hil)
        self.assertIn("command_sent = False", hil)
        self.assertNotIn("capture_gate_mismatch", hil)
        self.assertIn("last_stream_error", FIRMWARE_MAIN.read_text(encoding="utf-8"))

    def test_audio_hil_does_not_open_usb_serial_during_measurement(self) -> None:
        source = HIL.read_text(encoding="utf-8")
        self.assertNotIn("serial.Serial", source)
        self.assertNotIn("send_command(", source)
        self.assertIn('stopped_probe.get("stream_frames_sent"', source)

    def test_audio_hil_uses_the_background_safe_status_item(self) -> None:
        source = HIL.read_text(encoding="utf-8")

        self.assertIn("click menu bar item 1 of menu bar 2", source)
        self.assertIn('whose name contains "麦克风"', source)
        self.assertNotIn('AXIdentifier\\" of element', source)

    def test_udp_send_is_nonblocking_and_redundant(self) -> None:
        source = DEVICE_AUDIO.read_text(encoding="utf-8")
        self.assertIn("SOCK_DGRAM", source)
        self.assertIn("O_NONBLOCK", source)
        self.assertIn("kAudioRedundantDatagramBytes", source)
        self.assertIn("kAudioRedundancyLagFrames", source)
        self.assertIn(
            "kAudioRedundancyLagFrames = 5",
            AUDIO_PACKET.read_text(encoding="utf-8"),
        )
        self.assertIn("redundancy_history", source)
        self.assertIn("kSendRetryCount = 3", source)
        self.assertIn("error == ENOMEM", source)
        self.assertIn("vTaskDelay(pdMS_TO_TICKS(kSendRetryDelayMs))", source)
        self.assertIn("kTestPacketCount = 5", source)
        self.assertIn("kEndPacketCount = 3", source)
        self.assertIn("s_capture_ring_high_water", source)
        self.assertIn("s_maximum_capture_gap_ms", source)
        self.assertIn("s_maximum_transport_gap_ms", source)
        self.assertIn("recording_interval_active", source)
        self.assertIn("kAudioFlagMuted | kAudioFlagEnd", source)
        self.assertNotIn("SOCK_STREAM", source)
        self.assertNotIn("send_all", source)

    def test_udp_session_establishment_survives_transient_loss(self) -> None:
        source = DEVICE_AUDIO.read_text(encoding="utf-8")
        main = FIRMWARE_MAIN.read_text(encoding="utf-8")

        self.assertIn("kProofRetryIntervalMs = 500", source)
        self.assertIn("send_session_proofs(", source)
        self.assertIn("now_ms - last_proof_attempt_ms", source)
        self.assertIn("same_audio_offer", source)
        self.assertIn("same_audio_offer(s_offer, offer);", source)
        self.assertIn("if (unchanged)", source)
        connect = source[
            source.index("int connect_audio_stream("):
            source.index("void audio_capture_task(")
        ]
        self.assertLess(connect.index("connect("), connect.index("O_NONBLOCK"))
        self.assertIn("WIFI_PS_NONE", source[source.index("bool device_audio_apply_offer"):])
        self.assertIn(r'\"of\":%u', main)
        self.assertIn("g_audio_offer_rejected", main)
        self.assertIn("g_audio_offer_state_dirty.exchange", main)
        offer_case = main[
            main.index("case PendingControlKind::kAudioOffer:"):
            main.index("case PendingControlKind::kAudioReady:")
        ]
        self.assertIn("device_audio_apply_offer", offer_case)
        self.assertIn("publish_state(domain.state())", offer_case)
        controller = BLE_CONTROLLER.read_text(encoding="utf-8")
        self.assertIn('"last_command_type": lastCommandType', controller)
        self.assertIn('"last_command_bytes": lastCommandBytes', controller)

    def test_live_audio_disables_wifi_sleep_without_starving_ble_control(self) -> None:
        device_audio = DEVICE_AUDIO.read_text(encoding="utf-8")
        controller = BLE_CONTROLLER.read_text(encoding="utf-8")
        lease = CONTROL_LEASE.read_text(encoding="utf-8")
        firmware_main = FIRMWARE_MAIN.read_text(encoding="utf-8")

        self.assertNotIn("ESP_COEX_PREFER_WIFI", device_audio)
        self.assertIn("WIFI_PS_NONE", device_audio)
        self.assertIn("WIFI_PS_MIN_MODEM", device_audio)
        self.assertIn("set_runtime_wifi_power_save", device_audio)
        self.assertIn("wifi power-save transition failed", device_audio)
        self.assertIn("? 3.0 : 1.0", controller)
        self.assertIn("kLiveLeaseMilliseconds = 15'000", lease)
        self.assertIn(
            "if (domain.state().capture_gate != cardbridge::CaptureGate::kOpen)",
            firmware_main,
        )

    def test_firmware_audio_is_plaintext_without_cipher_context(self) -> None:
        source = DEVICE_AUDIO.read_text(encoding="utf-8")
        self.assertIn("encode_audio_packet(", source)
        for forbidden in ("mbedtls_", "psa_aead_encrypt", "psa_import_key",
                          "cipher_context", "offer.key", "SOCK_STREAM"):
            self.assertNotIn(forbidden, source)

    def test_firmware_reserves_ram_for_live_capture_not_idle_queues(self) -> None:
        audio = DEVICE_AUDIO.read_text(encoding="utf-8")
        main = FIRMWARE_MAIN.read_text(encoding="utf-8")

        self.assertIn("constexpr std::size_t kCaptureRingFrames = 10", audio)
        self.assertIn("redundancy_history", audio)
        self.assertIn("AudioTransportWorkspace", audio)
        self.assertIn('"audio_stream",\n        8192,', audio)
        self.assertIn("datagram.begin() + kAudioStreamFrameBytes", audio)
        self.assertIn("constexpr UBaseType_t kMicrophoneTaskPriority = 10", audio)
        self.assertIn("constexpr UBaseType_t kCaptureTaskPriority = 8", audio)
        self.assertIn("constexpr UBaseType_t kTransportTaskPriority = 9", audio)
        self.assertIn("redundancy_history_count = 0;", audio)
        self.assertIn("audio_frames_match_redundancy_lag", audio)
        self.assertIn("microphone_config.task_priority = kMicrophoneTaskPriority", audio)
        self.assertIn("microphone_config.task_pinned_core = kCaptureTaskCore", audio)
        self.assertIn("constexpr BaseType_t kCaptureTaskCore = 1", audio)
        self.assertIn("constexpr BaseType_t kTransportTaskCore = 1", audio)
        self.assertEqual(audio.count("xTaskCreatePinnedToCore("), 2)
        self.assertIn('"audio_capture",\n        4096,', audio)
        self.assertIn(
            "xQueueCreate(8, sizeof(PendingControlCommand))",
            main,
        )

    def test_candidate_cannot_replace_stream_before_session_probes(self) -> None:
        source = RECEIVER.read_text(encoding="utf-8")
        accept = source[
            source.index("private func accept("):
            source.index("private func remove(")
        ]
        authenticate = source[
            source.index("private func validateCandidate("):
            source.index("private func consumeValidated(")
        ]

        self.assertNotIn("connections.removeAll()", accept)
        self.assertIn("frame.flags.contains(.test)", authenticate)
        self.assertIn("frame.flags.contains(.muted)", authenticate)
        self.assertIn("guard frames.count == 3", authenticate)
        self.assertIn("frame.sequence == previous.sequence", authenticate)
        self.assertIn("frames = []", authenticate)
        self.assertIn(
            "AudioSessionRecovery.candidateValidationTimeoutSeconds",
            source,
        )
        self.assertLess(
            authenticate.index("guard frames.count == 3"),
            authenticate.index("activeConnectionID = identifier"),
        )

    def test_probe_and_ui_publication_are_throttled(self) -> None:
        source = RECEIVER.read_text(encoding="utf-8")

        self.assertIn("streamPublishIntervalNanoseconds: UInt64 = 100_000_000", source)
        self.assertIn("timer.schedule(deadline: .now() + 2, repeating: 2)", source)
        self.assertNotRegex(source, r"publishStreamProgress\(force:")
        self.assertIn("pendingStreamFault", source)

    def test_receiver_reports_udp_recovery_and_unrecovered_loss_separately(self) -> None:
        source = RECEIVER.read_text(encoding="utf-8")
        self.assertIn('"transport": "udp"', source)
        self.assertIn('"recovered_packets": metrics.recoveredPackets', source)
        self.assertIn("AudioRedundantDatagramV2.decode", source)
        self.assertIn("source: datagramFrame.isRedundant", source)
        self.assertIn('"maximum_receive_gap_ms"', source)
        self.assertIn('"receive_gap_over_100ms_count"', source)
        self.assertIn('"receive_gap_over_200ms_count"', source)

    def test_receiver_uses_one_redundancy_window_without_starving_playout(self) -> None:
        source = JITTER_BUFFER.read_text(encoding="utf-8")

        self.assertIn("reorderDepth = 5", source)
        self.assertNotIn("maximumReorderWaitFrames", source)
        self.assertIn("Int(highest - next) >= Self.reorderDepth", source)
        self.assertIn("concealedFrame", source)


if __name__ == "__main__":
    unittest.main()
