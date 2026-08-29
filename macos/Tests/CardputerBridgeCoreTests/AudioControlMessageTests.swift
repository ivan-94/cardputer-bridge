import CryptoKit
import XCTest
@testable import CardputerBridgeCore

final class AudioControlMessageTests: XCTestCase {
    func testAudioOfferFitsOneAuthenticatedGattWrite() throws {
        let offer = AudioOfferMessage(
            ipv4: "192.168.255.254",
            port: 65_535,
            sessionID: 0x0102030405060708,
            key: SymmetricKey(data: Data(0..<32))
        )

        let data = try offer.encoded()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertLessThanOrEqual(data.count, 160)
        XCTAssertEqual("audio_offer", json["type"] as? String)
        XCTAssertEqual("0102030405060708", json["sid"] as? String)
        XCTAssertEqual(44, (json["key"] as? String)?.count)
    }

    func testAudioOfferDoesNotEscapeBase64Slashes() throws {
        let offer = AudioOfferMessage(
            ipv4: "192.168.2.109",
            port: 54_321,
            sessionID: 0x0102030405060708,
            key: SymmetricKey(data: Data(repeating: 0xff, count: 32))
        )

        let wire = try offer.encoded()
        let text = String(decoding: wire, as: UTF8.self)

        XCTAssertTrue(text.contains("////"))
        XCTAssertFalse(text.contains("\\/"))
    }

    func testMaximumWifiCredentialsAreSplitIntoBoundedEncryptedWrites() throws {
        let messages = WiFiProvisioningMessages(
            ssid: String(repeating: "s", count: 32),
            password: String(repeating: "p", count: 63)
        )

        let writes = try messages.encodedWrites()

        XCTAssertEqual(3, writes.count)
        XCTAssertTrue(writes.allSatisfy { $0.count <= 160 })
        XCTAssertFalse(writes.contains { String(decoding: $0, as: UTF8.self).contains("pppp") })
    }
}
