import unittest
from unittest.mock import patch
from pathlib import Path
import plistlib
import subprocess
import tempfile

from harness.verifier.audio_bundle import verify


PROJECT_DIR = Path(__file__).resolve().parents[2]


class AudioBundleVerifierTests(unittest.TestCase):
    def test_known_bad_bundle_fails_with_stable_reason(self) -> None:
        bundle = PROJECT_DIR / "harness" / "fixtures" / "invalid-audio.driver"

        result = verify(bundle)

        self.assertFalse(result["valid"])
        self.assertIn("executable_missing", result["errors"])

    def test_rejects_audio_type_linking_to_a_different_factory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "WrongMapping.driver"
            executable = bundle / "Contents" / "MacOS" / "WrongMapping"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            info = {
                "CFBundleExecutable": "WrongMapping",
                "CFBundlePackageType": "BNDL",
                "CFPlugInFactories": {
                    "GOOD-FACTORY": "CardputerBridgeAudioFactory",
                    "OTHER-FACTORY": "OtherFactory",
                },
                "CFPlugInTypes": {
                    "443ABAB8-E7B3-491A-B985-BEB9187030DB": ["OTHER-FACTORY"],
                },
            }
            with (bundle / "Contents" / "Info.plist").open("wb") as handle:
                plistlib.dump(info, handle)
            nm_result = subprocess.CompletedProcess(
                args=["nm"], returncode=0, stdout="_CardputerBridgeAudioFactory\n", stderr=""
            )

            with patch("harness.verifier.audio_bundle.subprocess.run", return_value=nm_result):
                result = verify(bundle)

        self.assertFalse(result["valid"])
        self.assertIn("audio_type_factory_link_invalid", result["errors"])

    def test_rejects_bundle_without_audio_protocol_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "MissingProtocol.driver"
            executable = bundle / "Contents" / "MacOS" / "Driver"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            info = {
                "CFBundleExecutable": "Driver",
                "CFBundlePackageType": "BNDL",
                "CFPlugInFactories": {
                    "FACTORY": "CardputerBridgeAudioFactory",
                },
                "CFPlugInTypes": {
                    "443ABAB8-E7B3-491A-B985-BEB9187030DB": ["FACTORY"],
                },
            }
            with (bundle / "Contents" / "Info.plist").open("wb") as handle:
                plistlib.dump(info, handle)
            nm_result = subprocess.CompletedProcess(
                args=["nm"], returncode=0, stdout="_CardputerBridgeAudioFactory\n", stderr=""
            )

            with patch("harness.verifier.audio_bundle.subprocess.run", return_value=nm_result):
                result = verify(bundle)

        self.assertFalse(result["valid"])
        self.assertIn("audio_protocol_version_invalid", result["errors"])

    def test_rejects_bundle_without_authenticated_fd_broker_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "NamedSharedMemory.driver"
            executable = bundle / "Contents" / "MacOS" / "Driver"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            info = {
                "CFBundleExecutable": "Driver",
                "CFBundlePackageType": "BNDL",
                "CardputerBridgeAudioProtocolVersion": 1,
                "CardputerBridgeAudioFormat": "f32le-mono-48000",
                "CFPlugInFactories": {
                    "FACTORY": "CardputerBridgeAudioFactory",
                },
                "CFPlugInTypes": {
                    "443ABAB8-E7B3-491A-B985-BEB9187030DB": ["FACTORY"],
                },
            }
            with (bundle / "Contents" / "Info.plist").open("wb") as handle:
                plistlib.dump(info, handle)
            nm_result = subprocess.CompletedProcess(
                args=["nm"], returncode=0, stdout="_CardputerBridgeAudioFactory\n", stderr=""
            )

            with patch("harness.verifier.audio_bundle.subprocess.run", return_value=nm_result):
                result = verify(bundle)

        self.assertFalse(result["valid"])
        self.assertIn("audio_ipc_contract_invalid", result["errors"])
        self.assertIn("peer_auth_contract_invalid", result["errors"])


if __name__ == "__main__":
    unittest.main()
