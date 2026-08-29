from __future__ import annotations

import unittest

from scripts.launcher_install import (
    APP_DESCRIPTION_MAGIC,
    CHUNK_SIZE,
    LauncherInstallError,
    install_via_launcher,
    preflight_via_launcher,
    validate_application_image,
)


class FakeLauncherSerial:
    timeout = 0.01

    def __init__(
        self,
        expected_image: bytes,
        *,
        bad_ack: bool = False,
        running_bridge_app: bool = False,
    ) -> None:
        self.expected_image = expected_image
        self.bad_ack = bad_ack
        self.running_bridge_app = running_bridge_app
        self.lines: list[bytes] = []
        self.command_buffer = bytearray()
        self.payload = bytearray()
        self.payload_mode = False
        self.commands: list[str] = []

    def reset_input_buffer(self) -> None:
        self.lines.clear()

    def flush(self) -> None:
        return None

    def readline(self) -> bytes:
        if not self.lines:
            return b""
        return self.lines.pop(0)

    def write(self, data: bytes) -> int:
        if self.payload_mode:
            self.payload.extend(data)
            written = len(self.payload)
            ack_written = written - 1 if self.bad_ack and written >= CHUNK_SIZE else written
            self.lines.append(
                f"ACK {ack_written}/{len(self.expected_image)}\n".encode("ascii")
            )
            if written == len(self.expected_image):
                self.lines.append(b"OK flashed, rebooting\n")
                self.payload_mode = False
            return len(data)

        self.command_buffer.extend(data)
        if b"\n" not in self.command_buffer:
            return len(data)
        raw, _, rest = self.command_buffer.partition(b"\n")
        self.command_buffer = bytearray(rest)
        command = raw.decode("ascii")
        self.commands.append(command)
        if command == "version":
            if self.running_bridge_app:
                self.lines.extend(
                    [
                        b"I (203) app_init: Project name: cardputer_bridge_firmware\n",
                        b'{"v":1,"event":"ready","build_id":"cardputer-bridge-ff2"}\n',
                    ]
                )
            else:
                self.lines.append(b"Launcher 2.8.0\n")
        elif command == "partitions":
            self.lines.extend(
                [
                    b"== Partition table ==\n",
                    b"app0 type=app subtype=0x20 offset=0x010000 size=0x150000\n",
                    b"<free> offset=0x170000 size=0x690000 (6720KB)\n",
                    b"Flash size: 8MB, free total: 6720KB\n",
                ]
            )
        elif command == f"flash firmware cardbridge {len(self.expected_image)}":
            self.lines.append(f"READY {len(self.expected_image)}\n".encode("ascii"))
            self.payload_mode = True
        else:
            self.lines.append(b"ERR unknown command\n")
        return len(data)


def fake_application(size: int = 5000) -> bytes:
    image = bytearray([0xE9])
    image.extend(b"\x00" * 63)
    image.extend(APP_DESCRIPTION_MAGIC)
    image.extend(b"cardputer_bridge_firmware\x00")
    image.extend(b"\x5a" * (size - len(image)))
    return bytes(image)


class LauncherInstallTests(unittest.TestCase):
    def test_running_bridge_app_fails_immediately_with_power_cycle_action(self) -> None:
        image = fake_application()
        transport = FakeLauncherSerial(image, running_bridge_app=True)

        with self.assertRaisesRegex(
            LauncherInstallError,
            "device_running_cardputer_bridge_power_cycle_to_launcher",
        ):
            preflight_via_launcher(
                transport,
                image,
                port_label="fake://bridge-app",
            )

        self.assertEqual(transport.commands, ["version"])

    def test_preflight_never_sends_flash_command_or_payload(self) -> None:
        image = fake_application()
        transport = FakeLauncherSerial(image)
        evidence = preflight_via_launcher(
            transport,
            image,
            port_label="fake://launcher",
        )
        self.assertEqual(transport.commands, ["version", "partitions"])
        self.assertEqual(transport.payload, b"")
        self.assertEqual(evidence.result, "PASS")

    def test_streams_only_application_image_with_chunk_ack(self) -> None:
        image = fake_application()
        transport = FakeLauncherSerial(image)
        evidence = install_via_launcher(
            transport,
            image,
            "cardbridge",
            port_label="fake://launcher",
            image_path="firmware.bin",
        )
        self.assertEqual(
            transport.commands,
            ["version", "partitions", f"flash firmware cardbridge {len(image)}"],
        )
        self.assertEqual(bytes(transport.payload), image)
        self.assertEqual(evidence.bytes_acked, len(image))
        self.assertEqual(evidence.launcher_version, "2.8.0")
        self.assertEqual(evidence.result, "PASS")

    def test_rejects_non_application_before_serial_write(self) -> None:
        image = b"\xE9" + b"\x00" * 1024
        transport = FakeLauncherSerial(image)
        with self.assertRaisesRegex(LauncherInstallError, "descriptor"):
            install_via_launcher(
                transport,
                image,
                "cardbridge",
                port_label="fake://launcher",
                image_path="bootloader.bin",
            )
        self.assertEqual(transport.commands, [])
        self.assertEqual(transport.payload, b"")

    def test_ack_mismatch_fails_closed(self) -> None:
        image = fake_application()
        transport = FakeLauncherSerial(image, bad_ack=True)
        with self.assertRaisesRegex(LauncherInstallError, "ack_mismatch"):
            install_via_launcher(
                transport,
                image,
                "cardbridge",
                port_label="fake://launcher",
                image_path="firmware.bin",
            )
        self.assertLess(len(transport.payload), len(image))

    def test_image_validation_requires_esp_app_descriptor(self) -> None:
        with self.assertRaises(LauncherInstallError):
            validate_application_image(b"not an esp image")


if __name__ == "__main__":
    unittest.main()
