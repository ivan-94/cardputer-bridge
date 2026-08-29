import XCTest
@testable import CardputerBridgeCore

final class MicrophoneIntentAuthorityTests: XCTestCase {
    func testNewAppSessionDoesNotAdoptAStaleLiveDeviceIntent() {
        var authority = MicrophoneIntentAuthority()

        let needsCorrection = authority.observeDeviceIntent(.live)

        XCTAssertTrue(needsCorrection)
        XCTAssertEqual(authority.observed, .live)
        XCTAssertEqual(authority.desired, .muted)
        XCTAssertEqual(authority.heartbeatIntent, .muted)
    }

    func testUserToggleChangesDesiredIntentAndConvergesAfterDeviceAck() {
        var authority = MicrophoneIntentAuthority()
        XCTAssertFalse(authority.observeDeviceIntent(.muted))

        XCTAssertEqual(authority.toggleByUser(), .live)
        XCTAssertTrue(authority.observeDeviceIntent(.muted))
        XCTAssertFalse(authority.observeDeviceIntent(.live))
        XCTAssertEqual(authority.desired, .live)
        XCTAssertEqual(authority.observed, .live)
    }

    func testEveryConnectionSessionStartsMuted() {
        var authority = MicrophoneIntentAuthority()
        _ = authority.observeDeviceIntent(.muted)
        _ = authority.toggleByUser()
        _ = authority.observeDeviceIntent(.live)

        authority.beginConnectionSession()

        XCTAssertEqual(authority.desired, .muted)
        XCTAssertEqual(authority.heartbeatIntent, .muted)
    }

    func testUserPressDuringStaleLiveReportReinforcesMute() {
        var authority = MicrophoneIntentAuthority()
        _ = authority.observeDeviceIntent(.live)

        XCTAssertEqual(authority.toggleByUser(), .muted)
        XCTAssertEqual(authority.desired, .muted)
    }

    func testPhysicalG0ToggleBecomesDesiredAfterSafeBaseline() {
        var authority = MicrophoneIntentAuthority()
        XCTAssertFalse(authority.observeDeviceIntent(.muted))

        let needsCorrection = authority.observeDeviceIntent(.live)

        XCTAssertFalse(needsCorrection)
        XCTAssertEqual(authority.observed, .live)
        XCTAssertEqual(authority.desired, .live)
        XCTAssertEqual(authority.heartbeatIntent, .live)
    }

    func testPendingAppCommandIsNotOverriddenByOldDeviceState() {
        var authority = MicrophoneIntentAuthority()
        _ = authority.observeDeviceIntent(.muted)
        XCTAssertEqual(authority.toggleByUser(), .live)

        XCTAssertTrue(authority.observeDeviceIntent(.muted))
        XCTAssertEqual(authority.desired, .live)
        XCTAssertFalse(authority.observeDeviceIntent(.live))
    }
}
