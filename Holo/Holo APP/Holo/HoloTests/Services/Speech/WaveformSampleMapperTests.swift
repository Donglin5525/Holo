//
//  WaveformSampleMapperTests.swift
//  HoloTests
//
//  语音波形音量映射测试
//

import XCTest
@testable import Holo

final class WaveformSampleMapperTests: XCTestCase {

    func testSilenceMapsToFlatBaseline() {
        XCTAssertEqual(WaveformSampleMapper.normalizedAmplitude(fromPower: -80), 0)
    }

    func testQuietVoiceGetsVisibleAmplitude() {
        let amplitude = WaveformSampleMapper.normalizedAmplitude(fromPower: -42)

        XCTAssertGreaterThan(amplitude, 0.18)
    }

    func testLoudVoiceGetsStrongAmplitude() {
        let amplitude = WaveformSampleMapper.normalizedAmplitude(fromPower: -18)

        XCTAssertGreaterThan(amplitude, 0.72)
        XCTAssertLessThanOrEqual(amplitude, 1)
    }
}
