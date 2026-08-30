import CryptoKit
import XCTest
@testable import CardputerBridgeCore

final class FirmwareUpdateTests: XCTestCase {
    func testDeviceIdentityDecodesProductionCapabilities() throws {
        let data = Data(
            #"{"v":1,"device":"Cardputer-ADV","fw":"0.10.0","layout":2,"ota":true}"#.utf8
        )
        let identity = try XCTUnwrap(DeviceFirmwareIdentity.decode(from: data))
        XCTAssertEqual(identity.firmwareVersion, "0.10.0")
        XCTAssertEqual(identity.layoutVersion, 2)
        XCTAssertTrue(identity.otaCapable)
    }

    func testOldSinglePartitionDeviceRequiresUSBMigration() throws {
        let release = try FirmwareReleasePayload.fixture(version: "0.10.0")
        let device = FirmwareDeviceStatus(
            version: "0.9.7",
            layoutVersion: 1,
            otaCapable: false
        )

        XCTAssertEqual(
            FirmwareUpdatePolicy.plan(device: device, release: release),
            .usbMigrationRequired(targetVersion: "0.10.0")
        )
    }

    func testSignedManifestRejectsTamperedRelease() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = try FirmwareReleasePayload.fixture(version: "0.10.0")
        let signature = try privateKey.signature(for: payload.canonicalData())
        let manifest = SignedFirmwareRelease(
            payload: payload,
            signature: .init(
                algorithm: "ed25519",
                keyID: "test-key",
                value: signature.base64EncodedString()
            )
        )

        XCTAssertNoThrow(
            try manifest.verify(
                trustedKeys: ["test-key": privateKey.publicKey.rawRepresentation]
            )
        )

        let tampered = SignedFirmwareRelease(
            payload: try .fixture(version: "0.10.1"),
            signature: manifest.signature
        )
        XCTAssertThrowsError(
            try tampered.verify(
                trustedKeys: ["test-key": privateKey.publicKey.rawRepresentation]
            )
        )
    }

    func testProducerCompatibleManifestVerifiesWithEmbeddedTrustRoot() throws {
        let manifest = try JSONDecoder().decode(
            SignedFirmwareRelease.self,
            from: Data(Self.producerCompatibleManifest.utf8)
        )
        let canonicalPayload = try manifest.payload.canonicalData()

        XCTAssertEqual(canonicalPayload.count, 1_356)
        XCTAssertEqual(
            SHA256.hash(data: canonicalPayload).map { String(format: "%02x", $0) }.joined(),
            "3d044e2a374d6b760e0782704f90ede7ddc0bc93190d9ab0275cfbfdfc2322df"
        )

        XCTAssertNoThrow(
            try manifest.verify(trustedKeys: FirmwareReleaseTrust.productionKeys)
        )
    }

    func testExternalProductionManifestWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "CARDPUTER_RELEASE_MANIFEST_PATH"
        ] else {
            throw XCTSkip("No external release manifest was provided.")
        }
        let manifest = try JSONDecoder().decode(
            SignedFirmwareRelease.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        XCTAssertNoThrow(
            try manifest.verify(trustedKeys: FirmwareReleaseTrust.productionKeys)
        )
    }

    func testSignatureFailureHasActionableUserMessage() {
        XCTAssertEqual(
            FirmwareReleaseVerificationError.invalidSignature.errorDescription,
            "固件清单签名校验失败，已停止更新以保护设备。"
        )
    }

    func testHealthyOTADeviceNeverDowngradesToOlderStableRelease() throws {
        let release = try FirmwareReleasePayload.fixture(version: "0.10.0")
        let device = FirmwareDeviceStatus(
            version: "0.11.0",
            layoutVersion: 2,
            otaCapable: true
        )

        XCTAssertEqual(
            FirmwareUpdatePolicy.plan(device: device, release: release),
            .upToDate(version: "0.11.0")
        )
    }

    func testReleaseRequiringNewerMacAppFailsBeforeDeviceMutation() throws {
        let release = try FirmwareReleasePayload.fixture(
            version: "0.10.0",
            minimumMacOSAppVersion: "0.3.0"
        )
        let device = FirmwareDeviceStatus(
            version: "0.9.7",
            layoutVersion: 1,
            otaCapable: false
        )

        XCTAssertEqual(
            FirmwareUpdatePolicy.plan(
                device: device,
                release: release,
                appVersion: "0.2.0"
            ),
            .incompatible(reason: "macos_app_update_required")
        )
    }

    func testOTAStartCommandFitsOneEncryptedGATTWrite() throws {
        let message = FirmwareOTAStartMessage(
            version: "0.10.0",
            url: "https://github.com/ivan-94/cardputer-bridge/releases/latest/download/cardputer_bridge_firmware.bin"
        )

        let encoded = try message.encoded()

        XCTAssertLessThanOrEqual(encoded.count, 160)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("ota_start"))
    }

    func testEspflashCuAndTTYAliasesResolveToOnePhysicalDevice() {
        let output = "/dev/cu.usbmodem2101\n/dev/tty.usbmodem2101\n"

        XCTAssertEqual(
            USBSerialPortCatalog.canonicalPorts(from: output),
            ["/dev/cu.usbmodem2101"]
        )
    }

    func testTTYOnlyPortRemainsUsable() {
        XCTAssertEqual(
            USBSerialPortCatalog.canonicalPorts(from: "/dev/tty.usbmodem2101\n"),
            ["/dev/tty.usbmodem2101"]
        )
    }

    func testTwoPhysicalSerialDevicesRemainAmbiguous() {
        let output = """
        /dev/cu.usbmodem2101
        /dev/tty.usbmodem2101
        /dev/cu.usbmodem3101
        /dev/tty.usbmodem3101
        """

        XCTAssertEqual(
            USBSerialPortCatalog.canonicalPorts(from: output),
            ["/dev/cu.usbmodem2101", "/dev/cu.usbmodem3101"]
        )
    }

    func testBoardInfoConfirmsFlashableCardputerTarget() throws {
        let output = """
        Chip type:         esp32s3 (revision v0.2)
        Crystal frequency: 40 MHz
        Flash size:        8MB
        Features:          WiFi, BLE, Embedded Flash
        """

        XCTAssertEqual(
            USBFlashTargetProbe.validatedTarget(
                port: "/dev/cu.usbmodem2101",
                boardInfo: output
            ),
            USBFlashTarget(
                port: "/dev/cu.usbmodem2101",
                chip: "esp32s3",
                flashSizeMegabytes: 8
            )
        )
    }

    func testBoardInfoRejectsWrongChipAndUndersizedFlash() {
        XCTAssertNil(
            USBFlashTargetProbe.validatedTarget(
                port: "/dev/cu.usbserial1",
                boardInfo: "Chip type: esp32c3\nFlash size: 8MB"
            )
        )
        XCTAssertNil(
            USBFlashTargetProbe.validatedTarget(
                port: "/dev/cu.usbmodem1",
                boardInfo: "Chip type: esp32s3\nFlash size: 4MB"
            )
        )
    }

    func testBootEvidenceRequiresCardputerReadyOrSerialDiagnostic() {
        XCTAssertTrue(
            FirmwareBootEvidence.confirmsRunningFirmware(
                #"{"v":1,"event":"ready","board":"Cardputer-ADV","keyboard_ready":true}"#
            )
        )
        XCTAssertTrue(
            FirmwareBootEvidence.confirmsRunningFirmware(
                #"{"v":1,"event":"ready","board":"CardputerADV","keyboard_ready":true}"#
            )
        )
        XCTAssertTrue(
            FirmwareBootEvidence.confirmsRunningFirmware(
                #"{"v":1,"event":"diagnostic_state","source":"serial"}"#
            )
        )
        XCTAssertFalse(
            FirmwareBootEvidence.confirmsRunningFirmware(
                #"{"v":1,"event":"ready","board":"other","keyboard_ready":true}"#
            )
        )
    }
}

private extension FirmwareUpdateTests {
    static let producerCompatibleManifest = #"""
    {
      "payload": {
        "channel": "stable",
        "firmware": {
          "chip": "esp32s3",
          "layout_version": 2,
          "ota": {
            "bytes": 1773568,
            "role": "ota",
            "sha256": "676e8f9691894b07fb6ed509f00654e896c4cb90e710e1f26672f4f1e9fc4604",
            "url": "https://github.com/ivan-94/cardputer-bridge/releases/download/v0.10.1/cardputer_bridge_firmware.bin"
          },
          "usb": [
            {
              "bytes": 1773568,
              "offset": "0x10000",
              "role": "factory",
              "sha256": "676e8f9691894b07fb6ed509f00654e896c4cb90e710e1f26672f4f1e9fc4604",
              "url": "https://github.com/ivan-94/cardputer-bridge/releases/download/v0.10.1/cardputer_bridge_firmware.bin"
            },
            {
              "bytes": 8192,
              "offset": "0x610000",
              "role": "otadata",
              "sha256": "7d2c7ac4888bfd75cd5f56e8d61f69595121183afc81556c876732fd3782c62f",
              "url": "https://github.com/ivan-94/cardputer-bridge/releases/download/v0.10.1/ota_data_initial.bin"
            },
            {
              "bytes": 3072,
              "offset": "0x8000",
              "role": "partition_table",
              "sha256": "cfc32398e46bf6edb01102436e2530379574bd03cb257d29b742b8c47fadde7a",
              "url": "https://github.com/ivan-94/cardputer-bridge/releases/download/v0.10.1/partition-table.bin"
            },
            {
              "bytes": 20848,
              "offset": "0x0",
              "role": "bootloader",
              "sha256": "c3ea49948072b7a6d2611b2893b082fcb2b8ca1612c4831c9fce55b0f352fcef",
              "url": "https://github.com/ivan-94/cardputer-bridge/releases/download/v0.10.1/bootloader.bin"
            }
          ]
        },
        "minimum_macos_app_version": "0.2.0",
        "product": "cardputer-bridge",
        "published_at": "2026-08-29T12:54:23Z",
        "schema_version": 2,
        "version": "0.10.1"
      },
      "signature": {
        "algorithm": "ed25519",
        "key_id": "release-2026-01",
        "value": "23yHlBy8W1RqGkdz65sdGbgIlTlaE2AK+y2vBxxWjcHfwB3NbHF1UoTHvhQWKsj9dLLVVIKmYVEbEOHFx/K5Ag=="
      }
    }
    """#
}

private extension FirmwareReleasePayload {
    static func fixture(
        version: String,
        minimumMacOSAppVersion: String = "0.2.0"
    ) throws -> Self {
        FirmwareReleasePayload(
            schemaVersion: 2,
            product: "cardputer-bridge",
            channel: "stable",
            version: version,
            minimumMacOSAppVersion: minimumMacOSAppVersion,
            publishedAt: "2026-08-29T00:00:00Z",
            firmware: FirmwareReleasePayload.Firmware(
                chip: "esp32s3",
                layoutVersion: 2,
                ota: .init(
                    role: "ota",
                    url: "https://github.com/ivan-94/cardputer-bridge/releases/download/v\(version)/cardputer.bin",
                    bytes: 1_500_000,
                    sha256: String(repeating: "a", count: 64),
                    offset: nil
                ),
                usb: [
                    .init(role: "factory", url: artifactURL(version, "factory.bin"), bytes: 1_500_000, sha256: String(repeating: "b", count: 64), offset: "0x10000"),
                    .init(role: "otadata", url: artifactURL(version, "otadata.bin"), bytes: 8_192, sha256: String(repeating: "c", count: 64), offset: "0x610000"),
                    .init(role: "partition_table", url: artifactURL(version, "partition-table.bin"), bytes: 3_072, sha256: String(repeating: "d", count: 64), offset: "0x8000"),
                    .init(role: "bootloader", url: artifactURL(version, "bootloader.bin"), bytes: 20_000, sha256: String(repeating: "e", count: 64), offset: "0x0"),
                ]
            )
        )
    }

    static func artifactURL(_ version: String, _ name: String) -> String {
        "https://github.com/ivan-94/cardputer-bridge/releases/download/v\(version)/\(name)"
    }
}
