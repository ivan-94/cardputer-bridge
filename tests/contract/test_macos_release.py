import re
import subprocess
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
            "verify-macos-app-launch.sh",
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
        self.assertIn("needs: [firmware, macos, manifest-compatibility]", workflow)
        self.assertIn("actions/upload-artifact@v4", workflow)
        self.assertGreaterEqual(workflow.count("include-hidden-files: true"), 2)
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
        self.assertIn("Cardputer-Bridge-v*-macOS-arm64.dmg", workflow)
        self.assertIn("Cardputer-Bridge-v*-macOS-arm64.dmg.sha256", workflow)
        self.assertIn("ad-hoc", workflow)
        self.assertIn("--keyfile ../keys/firmware-signing-rsa3072.pem", workflow)
        self.assertIn("--keyfile ../keys/firmware-signing-rsa3072.pem\n            cardputer_bridge_firmware.bin", workflow)
        self.assertNotIn("--keyfile ../keys/firmware-signing-rsa3072.pem\n            build/cardputer_bridge_firmware.bin", workflow)
        self.assertNotIn(".release/*", workflow)

    def test_release_cross_checks_manifest_with_macos_trust_path(self) -> None:
        workflow = (PROJECT / ".github/workflows/release.yml").read_text()

        self.assertIn("manifest-compatibility:", workflow)
        self.assertIn("CARDPUTER_RELEASE_MANIFEST_PATH", workflow)
        self.assertIn("testExternalProductionManifestWhenProvided", workflow)

    def test_release_builder_creates_verified_drag_install_dmg(self) -> None:
        script = (PROJECT / "scripts/build-macos-release.sh").read_text()
        background = PROJECT / "packaging/macos/dmg/dmg-background.png"

        self.assertTrue(background.is_file())
        for required in (
            "create-dmg",
            "--app-drop-link",
            "--background",
            "安装说明.html",
            "hdiutil verify",
            "hdiutil attach",
            "Cardputer-Bridge-v${version}-macOS-arm64.dmg",
            "Cardputer-Bridge-v${version}-macOS-arm64.dmg.sha256",
        ):
            self.assertIn(required, script)

    def test_release_app_embeds_audio_driver_installer(self) -> None:
        script = (PROJECT / "scripts/build-macos-release.sh").read_text()
        embed_script = (PROJECT / "scripts/embed-audio-installer.sh").read_text()
        debug_build = (PROJECT / "scripts/build-macos.sh").read_text()
        debug_verify = (PROJECT / "scripts/verify-macos.sh").read_text()
        installer = (
            PROJECT
            / "packaging/macos/app-resources/AudioInstaller/install-bundled-audio-driver.sh"
        ).read_text()
        controller = (
            PROJECT / "macos/Sources/CardputerBridgeApp/AudioDriverInstallerController.swift"
        )

        self.assertTrue(controller.is_file())
        self.assertIn("embed-audio-installer.sh", script)
        self.assertIn("embed-audio-installer.sh", debug_build)
        self.assertIn("embed-audio-installer.sh", debug_verify)
        self.assertIn("AudioInstaller", embed_script)
        self.assertIn("CardputerBridgeAudio.driver.zip", embed_script)
        self.assertNotIn(
            'ditto "$driver" "$audio_installer_resources/Audio/CardputerBridgeAudio.driver"',
            embed_script,
        )
        self.assertIn("install-bundled-audio-driver.sh", embed_script)
        self.assertIn("CardputerBridgeAudio.driver.zip", installer)
        self.assertIn("ditto -x -k", installer)
        self.assertIn("with administrator privileges", controller.read_text())
        self.assertNotIn('"/bin/zsh "', controller.read_text())
        self.assertIn("userFacingInstallError", controller.read_text())
        self.assertNotIn(
            "phase = .failed(detail.trimmingCharacters",
            controller.read_text(),
        )

    @unittest.skipUnless(Path("/bin/zsh").is_file(), "requires macOS zsh")
    def test_bundled_audio_installer_runs_with_the_apps_zsh_interpreter(self) -> None:
        installer = (
            PROJECT
            / "packaging/macos/app-resources/AudioInstaller/install-bundled-audio-driver.sh"
        )

        result = subprocess.run(
            ["/bin/zsh", str(installer)],
            cwd=PROJECT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("需要 macOS 管理员权限", result.stderr)
        self.assertNotIn("BASH_SOURCE", result.stderr)

    def test_install_guide_covers_ad_hoc_gatekeeper_recovery(self) -> None:
        guide = (PROJECT / "packaging/macos/INSTALL.md").read_text()
        html = PROJECT / "packaging/macos/dmg/安装说明.html"
        html_text = html.read_text()

        self.assertTrue(html.is_file())
        for required in (
            "Apple 无法验证",
            "移动到废纸篓",
            "隐私与安全性",
            "仍要打开",
            "安装系统麦克风",
        ):
            self.assertIn(required, guide)
            self.assertIn(required, html_text)

        for rejected_workaround in (
            "Cardputer Bridge v@VERSION@.app",
            "v0.10.2",
        ):
            self.assertNotIn(rejected_workaround, guide)
            self.assertNotIn(rejected_workaround, html_text)

    def test_release_keeps_the_application_name_stable(self) -> None:
        project = (PROJECT / "macos/project.yml").read_text()

        self.assertIn("PRODUCT_NAME: Cardputer Bridge", project)
        self.assertIn("INFOPLIST_KEY_CFBundleDisplayName: Cardputer Bridge", project)
        self.assertNotIn("PRODUCT_NAME: Cardputer Bridge v", project)

    def test_release_notes_are_written_for_users(self) -> None:
        workflow = (PROJECT / ".github/workflows/release.yml").read_text()

        self.assertIn("下载 `macOS-arm64.dmg`", workflow)
        self.assertIn("设备、系统与网络要求", workflow)
        self.assertNotIn("Public Preview", workflow)
        self.assertNotIn("Secure Boot v2 格式的 RSA-3072", workflow)

    def test_readme_is_a_user_facing_product_guide(self) -> None:
        readme = (PROJECT / "README.md").read_text()

        for required in (
            "你需要准备",
            "Cardputer-ADV",
            "Apple Silicon",
            "2.4 GHz Wi-Fi",
            "USB-C",
            "管理员权限",
            "如果 macOS 阻止打开",
            "docs/images/app-overview.png",
            "docs/images/app-shortcuts.png",
            "docs/images/cardputer-adv-product.webp",
        ):
            self.assertIn(required, readme)

        for forbidden in (
            "当前公开预览版本",
            "当前代码已经实现",
            "已验证状态",
            "完整实机边界",
            "ESP-IDF Secure Boot v2",
            "RSA-3072",
            "v0.10.",
        ):
            self.assertNotIn(forbidden, readme)

        for image in (
            "app-overview.png",
            "app-shortcuts.png",
            "cardputer-adv-product.webp",
        ):
            self.assertTrue((PROJECT / "docs/images" / image).is_file())


if __name__ == "__main__":
    unittest.main()
