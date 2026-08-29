import base64
import csv
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.verify_firmware_release import parse_flash_args, verify_release


PROJECT = Path(__file__).resolve().parents[2]


class FirmwareReleaseContractTests(unittest.TestCase):
    def test_historical_hil_manifest_remains_truthful(self) -> None:
        manifest = json.loads(
            (PROJECT / "firmware-release.json").read_text(encoding="utf-8")
        )

        self.assertEqual(1, manifest["schema_version"])
        self.assertEqual("0.9.6-recording-led", manifest["candidate"])
        self.assertIn(manifest["state"], {"built-not-flashed", "flashed-verified"})
        self.assertEqual("esp32s3", manifest["chip"])
        self.assertEqual(8 * 1024 * 1024, manifest["flash_size_bytes"])
        self.assertEqual(3, manifest["expected_runtime"]["config_schema"])
        self.assertEqual("muted", manifest["expected_runtime"]["mic_intent"])
        self.assertEqual("closed", manifest["expected_runtime"]["capture_gate"])
        if manifest["state"] == "flashed-verified":
            self.assertEqual(
                manifest["artifacts"][1]["sha256"],
                manifest["verification"]["firmware_sha256"],
            )
            self.assertTrue(
                manifest["verification"]["evidence"].endswith(
                    "/finalization.json"
                )
            )
            self.assertTrue(all(manifest["verification"]["checks"].values()))
        else:
            self.assertNotIn("verification", manifest)

    def test_historical_finalize_stays_explicit_and_non_erasing(self) -> None:
        script = (PROJECT / "scripts/finalize-device.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("--preflight", script)
        self.assertIn("--flash-and-verify", script)
        self.assertIn("--verify-only", script)
        self.assertIn('verify_flash "@flash_args"', script)
        self.assertNotIn("read_flash", script)
        self.assertNotIn("full-flash.bin", script)
        self.assertNotIn("restore_command", script)
        self.assertNotIn("erase_flash", script)
        self.assertIn("--expected-schema 3", script)
        self.assertIn("FINALIZE_INCOMPLETE", script)
        self.assertLess(
            script.rindex("verify_firmware_release.py"),
            script.index('write_flash "@flash_args"'),
        )
        self.assertIn('"recording_led_hil": true', script)

    def test_historical_verifier_detects_hash_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "bootloader").mkdir()
            (root / "partition_table").mkdir()
            fixtures = {
                "0x0": ("bootloader/bootloader.bin", b"boot"),
                "0x10000": ("cardputer_bridge_firmware.bin", b"app"),
                "0x8000": ("partition_table/partition-table.bin", b"part"),
            }
            records = []
            for offset, (relative, body) in fixtures.items():
                (root / relative).write_bytes(body)
                records.append(
                    {
                        "offset": offset,
                        "path": relative,
                        "bytes": len(body),
                        "sha256": hashlib.sha256(body).hexdigest(),
                    }
                )
            flash_args = (
                "--flash_mode dio --flash_freq 80m --flash_size 8MB "
                "0x0 bootloader/bootloader.bin "
                "0x10000 cardputer_bridge_firmware.bin "
                "0x8000 partition_table/partition-table.bin\n"
            ).encode()
            (root / "flash_args").write_bytes(flash_args)
            manifest = {
                "schema_version": 1,
                "candidate": "0.9.6-recording-led",
                "state": "built-not-flashed",
                "chip": "esp32s3",
                "flash_size_bytes": 8 * 1024 * 1024,
                "baud": 460800,
                "artifacts": records,
                "flash_args": {
                    "path": "flash_args",
                    "bytes": len(flash_args),
                    "sha256": hashlib.sha256(flash_args).hexdigest(),
                },
                "expected_runtime": {
                    "build_id": "cardputer-bridge-phase3",
                    "config_schema": 3,
                    "mic_intent": "muted",
                    "capture_gate": "closed",
                },
            }
            manifest_path = root / "release.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            self.assertEqual("PASS", verify_release(manifest_path, root)["result"])
            (root / "cardputer_bridge_firmware.bin").write_bytes(b"changed")
            with self.assertRaisesRegex(AssertionError, "size_mismatch"):
                verify_release(manifest_path, root)

    def test_historical_flash_parser_rejects_unsafe_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "flash_args"
            path.write_text(
                "--flash_mode dio --flash_freq 80m --flash_size 8MB "
                "0x0 bootloader.bin 0x10000 app.bin 0x9000 partitions.bin",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(AssertionError, "offsets_invalid"):
                parse_flash_args(path)

    def test_partition_and_rollback_policy_are_production_safe(self) -> None:
        with (PROJECT / "firmware/partitions.csv").open() as stream:
            rows = {
                row[0].strip(): [column.strip() for column in row]
                for row in csv.reader(
                    line for line in stream if not line.startswith("#")
                )
                if row
            }

        self.assertEqual(rows["factory"][3:5], ["0x10000", "0x200000"])
        self.assertEqual(rows["ota_0"][3:5], ["0x210000", "0x200000"])
        self.assertEqual(rows["ota_1"][3:5], ["0x410000", "0x200000"])
        self.assertEqual(rows["otadata"][3:5], ["0x610000", "0x2000"])

        defaults = (PROJECT / "firmware/sdkconfig.defaults").read_text()
        production = (
            PROJECT / "firmware/sdkconfig.production.defaults"
        ).read_text()
        self.assertIn("CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y", defaults)
        self.assertIn("CONFIG_MBEDTLS_CERTIFICATE_BUNDLE=y", defaults)
        self.assertIn(
            "CONFIG_SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT=y", production
        )
        self.assertIn("CONFIG_SECURE_SIGNED_APPS_RSA_SCHEME=y", production)

    def test_ota_and_usb_paths_fail_closed(self) -> None:
        updater = (
            PROJECT
            / "firmware/components/firmware_update/firmware_update.cpp"
        ).read_text()
        for required in (
            "esp_crt_bundle_attach",
            "esp_https_ota_get_img_desc",
            '"cardputer_bridge_firmware"',
            "is_strictly_newer",
            "esp_https_ota_is_complete_data_received",
            "esp_https_ota_finish",
            "esp_https_ota_abort",
        ):
            self.assertIn(required, updater)

        main = (PROJECT / "firmware/main/main.cpp").read_text()
        self.assertIn(
            "!running_image_confirmed && keyboard_ready && now >= 10'000",
            main,
        )

        installer = (
            PROJECT
            / "macos/Sources/CardputerBridgeApp/FirmwareUpdateController.swift"
        ).read_text()
        self.assertNotIn('"erase-flash"', installer)
        role_positions = [
            installer.index(f'("{role}", "{offset}")')
            for role, offset in (
                ("factory", "0x10000"),
                ("otadata", "0x610000"),
                ("partition_table", "0x8000"),
                ("bootloader", "0x0"),
            )
        ]
        self.assertEqual(role_positions, sorted(role_positions))
        self.assertIn("SHA256.hash(data: data).hex", installer)
        self.assertIn("Task.detached(priority: .userInitiated)", installer)

    def test_manifest_generator_hashes_and_signs_exact_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build = root / "build"
            (build / "partition_table").mkdir(parents=True)
            (build / "bootloader").mkdir()
            fixtures = {
                "cardputer_bridge_firmware.bin": b"signed-factory",
                "ota_data_initial.bin": b"ota-state",
                "partition_table/partition-table.bin": b"partitions",
                "bootloader/bootloader.bin": b"bootloader",
            }
            for relative, contents in fixtures.items():
                (build / relative).write_bytes(contents)

            private_key = root / "release.pem"
            public_key = root / "release-public.pem"
            output = root / "manifest.json"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "ED25519", "-out", private_key],
                check=True,
                capture_output=True,
            )

            subprocess.run(
                [
                    "openssl",
                    "pkey",
                    "-in",
                    private_key,
                    "-pubout",
                    "-out",
                    public_key,
                ],
                check=True,
                capture_output=True,
            )

            subprocess.run(
                [
                    "python3",
                    PROJECT / "scripts/create-release-manifest.py",
                    "--version",
                    "0.10.0",
                    "--build-dir",
                    build,
                    "--signing-key",
                    private_key,
                    "--published-at",
                    "2026-08-29T00:00:00Z",
                    "--output",
                    output,
                ],
                check=True,
                capture_output=True,
            )

            manifest = json.loads(output.read_text())
            payload = manifest["payload"]
            self.assertEqual(payload["version"], "0.10.0")
            self.assertEqual(payload["firmware"]["layout_version"], 2)
            self.assertEqual(
                [item["role"] for item in payload["firmware"]["usb"]],
                ["factory", "otadata", "partition_table", "bootloader"],
            )
            self.assertEqual(
                payload["firmware"]["ota"]["sha256"],
                hashlib.sha256(fixtures["cardputer_bridge_firmware.bin"]).hexdigest(),
            )

            canonical = root / "canonical.json"
            signature = root / "signature.bin"
            canonical.write_bytes(
                json.dumps(
                    payload,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode()
            )
            signature.write_bytes(
                base64.b64decode(manifest["signature"]["value"])
            )
            subprocess.run(
                [
                    "openssl",
                    "pkeyutl",
                    "-verify",
                    "-rawin",
                    "-pubin",
                    "-inkey",
                    public_key,
                    "-in",
                    canonical,
                    "-sigfile",
                    signature,
                ],
                check=True,
                capture_output=True,
            )

    def test_release_workflow_binds_tag_to_embedded_firmware_version(self) -> None:
        workflow = (PROJECT / ".github/workflows/release.yml").read_text()
        self.assertIn(
            'grep -Fq "set(PROJECT_VER \\"$version\\")" firmware/CMakeLists.txt',
            workflow,
        )
        self.assertIn("secure-verify-signature --version 2", workflow)
        self.assertIn("RELEASE_MANIFEST_SIGNING_KEY_PEM", workflow)
        self.assertIn("FIRMWARE_SIGNING_KEY_PEM", workflow)


if __name__ == "__main__":
    unittest.main()
