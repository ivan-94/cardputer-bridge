import Foundation
import XCTest
@testable import CardputerBridgeCore

final class DiagnosticsReportTests: XCTestCase {
    func testReportExportsOnlyThePublicOperationalSnapshot() throws {
        let report = CardputerDiagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.1.0",
            blePhase: "ready",
            microphoneIntent: "muted",
            audioStatus: "receiving",
            systemMicrophoneReady: true,
            configurationSynced: true,
            wifiConnected: true,
            batteryPercent: 78,
            wifiRSSI: -53,
            acceptedPackets: 120,
            missingPackets: 2,
            duplicateOrLatePackets: 1,
            controlFault: nil,
            audioFault: nil
        )

        let data = try report.encodedJSON()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"battery_percent\" : 78"))
        XCTAssertTrue(text.contains("\"accepted_packets\" : 120"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("session_key"))
        XCTAssertFalse(text.contains("ssid"))
        XCTAssertFalse(text.contains("typed"))
        XCTAssertFalse(text.contains("audio_samples"))
    }
}
