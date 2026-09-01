import Foundation
import XCTest
@testable import CardputerBridgeCore

final class PCM16ResamplerTests: XCTestCase {
    func testConvertsSixtyMillisecondsToFortyEightKilohertzFloat() throws {
        let resampler = try PCM16ToFloat32Resampler(outputGain: 1)
        let input = Array(repeating: Int16(4_096), count: 960)
            .withUnsafeBytes { Data($0) }

        let output = try resampler.convert(input)

        XCTAssertEqual(output.count, 2_880)
        XCTAssertEqual(output[1_000], 0.125, accuracy: 0.005)
    }

    func testRepeatedTenMillisecondFramesKeepExactClockRatio() throws {
        let resampler = try PCM16ToFloat32Resampler(outputGain: 1)
        let input = Array(repeating: Int16(4_096), count: 160)
            .withUnsafeBytes { Data($0) }

        let frameCounts = try (0..<100).map { _ in
            try resampler.convert(input).count
        }

        XCTAssertEqual(Array(repeating: 480, count: 100), frameCounts)
        XCTAssertEqual(48_000, frameCounts.reduce(0, +))
    }

    func testRaisesSpeechLevelAndKeepsPeaksInsideFloatRange() throws {
        let resampler = try PCM16ToFloat32Resampler(outputGain: 2)
        let quiet = Array(repeating: Int16(3_276), count: 320)
            .withUnsafeBytes { Data($0) }
        let loud = Array(repeating: Int16.max, count: 320)
            .withUnsafeBytes { Data($0) }

        let raised = try resampler.convert(quiet)
        let limited = try resampler.convert(loud)

        XCTAssertEqual(raised[500], 0.2, accuracy: 0.015)
        XCTAssertLessThanOrEqual(limited.map(abs).max() ?? 2, 1)
        XCTAssertGreaterThan(limited[500], 0.9)
    }

    func testDefaultConversionAddsOnlyTwoDecibelsOfSpeechGain() throws {
        let resampler = try PCM16ToFloat32Resampler()
        let input = Array(repeating: Int16(3_276), count: 320)
            .withUnsafeBytes { Data($0) }

        let output = try resampler.convert(input)

        XCTAssertEqual(output[500], 0.125, accuracy: 0.01)
    }

    func testRejectsMalformedPCM16() throws {
        let resampler = try PCM16ToFloat32Resampler()
        XCTAssertThrowsError(try resampler.convert(Data([0x01])))
    }
}
