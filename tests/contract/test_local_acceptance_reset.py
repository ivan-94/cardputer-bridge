import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT / "scripts/reset-local-acceptance.sh"


class LocalAcceptanceResetContractTests(unittest.TestCase):
    def test_reset_requires_explicit_confirmation(self) -> None:
        result = subprocess.run(
            [str(SCRIPT)],
            cwd=PROJECT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("LOCAL_RESET_NOT_CONFIRMED", result.stderr)

    def test_reset_backs_up_user_state_without_touching_firmware(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            reset_home = Path(temporary_directory) / "home"
            application_support = (
                reset_home / "Library/Application Support/Cardputer Bridge"
            )
            preferences = (
                reset_home
                / "Library/Preferences/io.nexu.cardputerbridge.app.plist"
            )
            application_support.mkdir(parents=True)
            preferences.parent.mkdir(parents=True)
            (application_support / "config.json").write_text('{"version": 4}')
            preferences.write_text("preferences")

            environment = os.environ.copy()
            environment.update(
                {
                    "CARDPUTER_BRIDGE_TEST_MODE": "1",
                    "CARDPUTER_BRIDGE_RESET_HOME": str(reset_home),
                    "CARDPUTER_BRIDGE_RESET_BACKUP_ROOT": str(
                        reset_home / "backups"
                    ),
                }
            )
            result = subprocess.run(
                [str(SCRIPT), "--confirm-reset"],
                cwd=PROJECT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(application_support.exists())
            self.assertFalse(preferences.exists())
            backups = list((reset_home / "backups").glob("*"))
            self.assertEqual(len(backups), 1)
            self.assertTrue((backups[0] / "Application Support/config.json").is_file())
            self.assertTrue(
                (backups[0] / "io.nexu.cardputerbridge.app.plist").is_file()
            )
            self.assertIn("cardputer_firmware=true", result.stdout)
            self.assertIn("bluetooth_bond=true", result.stdout)

    def test_script_has_no_recursive_delete_or_device_flash_command(self) -> None:
        source = SCRIPT.read_text()

        self.assertNotIn("rm -rf", source)
        self.assertNotIn("esptool", source)
        self.assertNotIn("espflash", source)
        self.assertNotIn("idf.py flash", source)


if __name__ == "__main__":
    unittest.main()
