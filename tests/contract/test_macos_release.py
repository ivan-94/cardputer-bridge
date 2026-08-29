import re
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[2]


class MacOSReleaseContractTests(unittest.TestCase):
    def test_app_and_firmware_share_release_version(self) -> None:
        firmware = (PROJECT / "firmware/CMakeLists.txt").read_text()
        project = (PROJECT / "macos/project.yml").read_text()

        firmware_versions = re.findall(
            r'set\(PROJECT_VER "([^"]+)"\)',
            firmware,
        )
        app_version = re.search(r"MARKETING_VERSION:\s*([^\s]+)", project)
        self.assertTrue(firmware_versions)
        self.assertIsNotNone(app_version)
        self.assertEqual(firmware_versions[-1], app_version.group(1))

    def test_release_builder_creates_verified_ad_hoc_archive(self) -> None:
        script = (PROJECT / "scripts/build-macos-release.sh").read_text()

        for required in (
            "-configuration Release",
            'codesign --force --deep --sign - "$app"',
            'codesign --verify --deep --strict "$app"',
            'codesign --verify --deep --strict "$driver"',
            "CFBundleShortVersionString",
            "--sequesterRsrc",
            "--keepParent",
            "shasum -a 256",
            "INSTALL.md",
            "install-audio-plugin.command",
            "uninstall-audio-plugin.command",
            "restore-audio-plugin.command",
            "check-audio-hal-runtime.sh",
        ):
            self.assertIn(required, script)
        self.assertNotIn("Developer ID", script)

    def test_audio_installer_is_explicit_and_path_scoped(self) -> None:
        installer = (
            PROJECT / "packaging/macos/install-audio-plugin.command"
        ).read_text()
        uninstaller = (
            PROJECT / "packaging/macos/uninstall-audio-plugin.command"
        ).read_text()
        restorer = (
            PROJECT / "packaging/macos/restore-audio-plugin.command"
        ).read_text()

        self.assertIn("/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver", installer)
        self.assertIn('read -r confirmation', installer)
        self.assertIn('[[ "$confirmation" == "INSTALL" ]]', installer)
        self.assertIn("codesign --verify --deep --strict", installer)
        self.assertIn("CardputerBridgeAudio.install.", installer)
        self.assertIn('"$preflight"', installer)
        self.assertIn("管理员权限", installer)
        self.assertIn("重载 Core Audio", installer)
        self.assertNotIn("rm -rf", installer)

        self.assertIn("/Library/Audio/Plug-Ins/HAL/CardputerBridgeAudio.driver", uninstaller)
        self.assertIn('read -r confirmation', uninstaller)
        self.assertIn('[[ "$confirmation" == "UNINSTALL" ]]', uninstaller)
        self.assertNotIn("rm -rf", uninstaller)

        self.assertIn('[[ "$confirmation" == "RESTORE" ]]', restorer)
        self.assertIn("CardputerBridgeAudio.driver.", restorer)
        self.assertNotIn("rm -rf", restorer)

    def test_tag_release_publishes_firmware_and_macos_assets(self) -> None:
        workflow = (PROJECT / ".github/workflows/release.yml").read_text()

        self.assertIn("macos:", workflow)
        self.assertIn("publish:", workflow)
        self.assertIn("needs: [firmware, macos]", workflow)
        self.assertIn("actions/upload-artifact@v4", workflow)
        self.assertIn("actions/download-artifact@v4", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("--draft", workflow)
        self.assertIn("gh release upload", workflow)
        self.assertIn("--draft=false", workflow)
        self.assertIn("--prerelease=false", workflow)
        self.assertIn("--latest", workflow)
        self.assertIn("stat -c %s", workflow)
        self.assertIn("@tsv", workflow)
        self.assertIn('test "$actual_assets" = "$expected_assets"', workflow)
        self.assertIn("./scripts/verify-macos.sh", workflow)
        self.assertIn("./scripts/build-macos-release.sh", workflow)
        self.assertIn("Cardputer-Bridge-v*-macOS-arm64.zip", workflow)
        self.assertIn("Cardputer-Bridge-v*-macOS-arm64.sha256", workflow)
        self.assertIn("ad-hoc", workflow)
        self.assertNotIn(".release/*", workflow)


if __name__ == "__main__":
    unittest.main()
