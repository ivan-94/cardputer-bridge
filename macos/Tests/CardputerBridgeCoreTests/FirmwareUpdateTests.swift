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
