from __future__ import annotations

import unittest

from scripts.verify_runtime_hil import decode_diagnostic, send_command


class RuntimeHILVerifierTests(unittest.TestCase):
    def test_send_command_does_not_call_tcdrain_style_flush(self) -> None:
        class Transport:
            def __init__(self) -> None:
                self.written = b""

            def write(self, payload: bytes) -> int:
                self.written += payload
                return len(payload)

            def flush(self) -> None:
                raise AssertionError("serial flush may block forever in tcdrain")

            def readline(self) -> bytes:
                return (
                    b'{"v":1,"event":"diagnostic_state",'
                    b'"source":"serial"}\n'
                )

        transport = Transport()

        event = send_command(transport, "status")

        self.assertEqual(b"status\r\n", transport.written)
        self.assertEqual("serial", event["source"])

    def test_decodes_diagnostic_after_interleaved_boot_log(self) -> None:
        raw = (
            b"I (181) esp_image: segment "
            b'{"v":1,"event":"diagnostic_state","source":"serial",'
            b'"mic_intent":"muted"}\n'
        )

        event = decode_diagnostic(raw)

        self.assertIsNotNone(event)
        self.assertEqual("serial", event["source"])

    def test_prefers_complete_final_event_after_interrupted_telemetry(self) -> None:
        raw = (
            b'{"v":1,"event":"diagnostic_state","source":"telemetry","mic_inte'
            b'{"v":1,"event":"diagnostic_state","source":"serial",'
            b'"mic_intent":"muted"}\n'
        )

        event = decode_diagnostic(raw)

        self.assertIsNotNone(event)
        self.assertEqual("serial", event["source"])

    def test_rejects_unstructured_output(self) -> None:
        self.assertIsNone(decode_diagnostic(b"I (24) boot: normal output\n"))


if __name__ == "__main__":
    unittest.main()
