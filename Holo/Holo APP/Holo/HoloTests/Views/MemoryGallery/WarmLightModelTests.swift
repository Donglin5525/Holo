//
//  WarmLightModelTests.swift
//  HoloTests
//
//  「一束暖光」时间线纯函数单测（暖光规格 §4.2/§4.3/§7.1）：
//  - CSS 贝塞尔求解器（ease-out / ease-in-out 关键点）
//  - 正常时间线 8 个关键帧逐项对上实测表（画布 367×336）
//  - 减少动态分支（850ms 光形定态、亮度走 ease-out、1060ms 收尾）
//  - 预乘 alpha 密集渐变色标
//

import XCTest
import CoreGraphics
@testable import Holo

final class WarmLightModelTests: XCTestCase {
    private let canvas = CGSize(width: 367, height: 336)
    private var timeline: WarmLightTimeline { WarmLightTimeline(reduceMotion: false) }

    // MARK: - 贝塞尔求解器

    func testEaseOutSolverMatchesCSSKeypoints() {
        // x=0.172414（250ms 主段进度）→ y≈0.2686（关键帧表反解值）
        XCTAssertEqual(WarmLightEasing.easeOut.value(atX: 0.172414), 0.2686, accuracy: 0.001)
        // x=0.5（1555ms 淡出中点）→ y≈0.6846，对应合成层 0.315（手算复核值）
        XCTAssertEqual(WarmLightEasing.easeOut.value(atX: 0.5), 0.6846, accuracy: 0.001)
        XCTAssertEqual(WarmLightEasing.easeOut.value(atX: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(WarmLightEasing.easeOut.value(atX: 1), 1, accuracy: 1e-9)
    }

    func testEaseInOutSolverMidpointAndSymmetry() {
        XCTAssertEqual(WarmLightEasing.easeInOut.value(atX: 0.5), 0.5, accuracy: 1e-6)
        // 对称曲线：y(x) + y(1-x) = 1
        for x in stride(from: 0.1, through: 0.9, by: 0.1) {
            let y = WarmLightEasing.easeInOut.value(atX: x)
            let mirrored = WarmLightEasing.easeInOut.value(atX: 1 - x)
            XCTAssertEqual(y + mirrored, 1, accuracy: 1e-6)
        }
    }

    func testSolverIsMonotonic() {
        var last = -1.0
        for i in 0...20 {
            let x = Double(i) / 20
            let y = WarmLightEasing.easeOut.value(atX: x)
            XCTAssertGreaterThanOrEqual(y, last - 1e-9)
            last = y
        }
    }

    // MARK: - 正常时间线关键帧（暖光规格 §4.2 实测表）

    func testKeyframeAt0ms() {
        let f = timeline.frame(at: 0, canvas: canvas)
        XCTAssertEqual(f.departureAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(f.arrivalAlpha, 0, accuracy: 1e-9)
        XCTAssertEqual(f.glowAlpha, 0.18, accuracy: 1e-9)
        XCTAssertEqual(f.glowScale, 0.74, accuracy: 1e-9)
        // 初态位移 = (-0.16·Gw, +0.13·Gh)，G = 1.4×画布
        XCTAssertEqual(f.glowOffset.width, -82.21, accuracy: 0.05)
        XCTAssertEqual(f.glowOffset.height, 61.15, accuracy: 0.05)
        XCTAssertEqual(f.compositeAlpha, 1, accuracy: 1e-9)
    }

    func testKeyframeAt250ms() {
        let f = timeline.frame(at: 0.25, canvas: canvas)
        XCTAssertEqual(f.departureAlpha, 0.883, accuracy: 0.004)
        XCTAssertEqual(f.arrivalAlpha, 0, accuracy: 1e-9)
        XCTAssertEqual(f.glowAlpha, 0.400, accuracy: 0.002)
        XCTAssertEqual(f.glowScale, 0.810, accuracy: 0.002)
        XCTAssertEqual(f.glowOffset.width, -60.12, accuracy: 0.2)
        XCTAssertEqual(f.glowOffset.height, 44.72, accuracy: 0.2)
        XCTAssertEqual(f.compositeAlpha, 1, accuracy: 1e-9)
    }

    func testKeyframeAt500ms() {
        let f = timeline.frame(at: 0.5, canvas: canvas)
        XCTAssertEqual(f.departureAlpha, 0, accuracy: 0.004)
        XCTAssertEqual(f.arrivalAlpha, 0.029, accuracy: 0.004)
        XCTAssertEqual(f.glowAlpha, 0.592, accuracy: 0.003)
        XCTAssertEqual(f.glowScale, 0.871, accuracy: 0.002)
        XCTAssertEqual(f.glowOffset.width, -40.86, accuracy: 0.25)
        XCTAssertEqual(f.glowOffset.height, 30.39, accuracy: 0.25)
        XCTAssertEqual(f.compositeAlpha, 1, accuracy: 1e-9)
    }

    func testKeyframeAt700ms() {
        let f = timeline.frame(at: 0.7, canvas: canvas)
        XCTAssertEqual(f.departureAlpha, 0, accuracy: 1e-9)
        XCTAssertEqual(f.arrivalAlpha, 0.490, accuracy: 0.005)
        XCTAssertEqual(f.glowAlpha, 0.726, accuracy: 0.003)
        XCTAssertEqual(f.glowScale, 0.913, accuracy: 0.002)
        XCTAssertEqual(f.glowOffset.width, -27.46, accuracy: 0.25)
        XCTAssertEqual(f.glowOffset.height, 20.43, accuracy: 0.25)
        XCTAssertEqual(f.compositeAlpha, 1, accuracy: 1e-9)
    }

    func testKeyframeAt1000ms() {
        let f = timeline.frame(at: 1.0, canvas: canvas)
        XCTAssertEqual(f.departureAlpha, 0, accuracy: 1e-9)
        XCTAssertEqual(f.arrivalAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(f.glowAlpha, 0.887, accuracy: 0.002)
        XCTAssertEqual(f.glowScale, 0.964, accuracy: 0.002)
        XCTAssertEqual(f.glowOffset.width, -11.31, accuracy: 0.25)
        XCTAssertEqual(f.glowOffset.height, 8.42, accuracy: 0.25)
        XCTAssertEqual(f.compositeAlpha, 1, accuracy: 1e-9)
    }

    func testKeyframeAt1450ms() {
        let f = timeline.frame(at: 1.45, canvas: canvas)
        XCTAssertEqual(f.departureAlpha, 0, accuracy: 1e-9)
        XCTAssertEqual(f.arrivalAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(f.glowAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(f.glowScale, 1, accuracy: 1e-9)
        XCTAssertEqual(f.glowOffset, .zero)
        XCTAssertEqual(f.compositeAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(timeline.handoffElapsed, 1.45)
    }

    func testKeyframeAt1555ms() {
        let f = timeline.frame(at: 1.555, canvas: canvas)
        XCTAssertEqual(f.compositeAlpha, 0.315, accuracy: 0.004)
        XCTAssertEqual(f.arrivalAlpha, 1, accuracy: 1e-9)
    }

    func testKeyframeAt1660msAndBeyond() {
        let f = timeline.frame(at: 1.66, canvas: canvas)
        XCTAssertEqual(f.compositeAlpha, 0, accuracy: 1e-6)
        let later = timeline.frame(at: 3.0, canvas: canvas)
        XCTAssertEqual(later.compositeAlpha, 0, accuracy: 1e-9)
    }

    func testNegativeElapsedClampsToZero() {
        let f = timeline.frame(at: -0.5, canvas: canvas)
        XCTAssertEqual(f.glowAlpha, 0.18, accuracy: 1e-9)
        XCTAssertEqual(f.departureAlpha, 1, accuracy: 1e-9)
    }

    func testDurationsWireToHoloAnimationTokens() {
        XCTAssertEqual(timeline.mainDuration, HoloAnimation.warmLightMainDuration)
        XCTAssertEqual(timeline.fadeDuration, HoloAnimation.warmLightFadeDuration)
        XCTAssertEqual(timeline.totalDuration, 1.66, accuracy: 1e-9)
    }

    // MARK: - 减少动态（暖光规格 §4.3）

    func testReducedMotionDurations() {
        let reduced = WarmLightTimeline(reduceMotion: true)
        XCTAssertEqual(reduced.mainDuration, HoloAnimation.warmLightReducedMainDuration)
        XCTAssertEqual(reduced.mainDuration, 0.85, accuracy: 1e-9)
        XCTAssertEqual(reduced.totalDuration, 1.06, accuracy: 1e-9)
    }

    func testReducedMotionGlowFixedAtFinalGeometry() {
        let reduced = WarmLightTimeline(reduceMotion: true)
        for t in stride(from: 0.0, through: 1.06, by: 0.1) {
            let f = reduced.frame(at: t, canvas: canvas)
            XCTAssertEqual(f.glowScale, 1, accuracy: 1e-9)
            XCTAssertEqual(f.glowOffset, .zero)
        }
    }

    func testReducedMotionBrightnessCurves() {
        let reduced = WarmLightTimeline(reduceMotion: true)
        // 30% 前亮度为 0；67% 后为 1；中途走 ease-out。
        XCTAssertEqual(reduced.frame(at: 0, canvas: canvas).glowAlpha, 0, accuracy: 1e-9)
        XCTAssertEqual(reduced.frame(at: 0.25, canvas: canvas).glowAlpha, 0, accuracy: 1e-9)
        let mid = reduced.frame(at: 0.4, canvas: canvas).glowAlpha
        XCTAssertGreaterThan(mid, 0.5)
        XCTAssertLessThan(mid, 0.75)
        XCTAssertEqual(reduced.frame(at: 0.6, canvas: canvas).glowAlpha, 1, accuracy: 1e-9)
        // 文案保留原百分比关键点（12%/34% 与 30%/67% 作用于 850ms）。
        XCTAssertEqual(reduced.frame(at: 0, canvas: canvas).departureAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(reduced.frame(at: 0.3, canvas: canvas).departureAlpha, 0, accuracy: 1e-9)
        // 抵达组 30%=255ms 才开始淡入：0.25s 仍为 0；0.3s 已进窗口（不再断言为 0）。
        XCTAssertEqual(reduced.frame(at: 0.25, canvas: canvas).arrivalAlpha, 0, accuracy: 1e-9)
        XCTAssertEqual(reduced.frame(at: 0.6, canvas: canvas).arrivalAlpha, 1, accuracy: 1e-9)
        // 主段末合成层仍为 1，1060ms 归零。
        XCTAssertEqual(reduced.frame(at: 0.85, canvas: canvas).compositeAlpha, 1, accuracy: 1e-9)
        XCTAssertEqual(reduced.frame(at: 1.06, canvas: canvas).compositeAlpha, 0, accuracy: 1e-6)
    }

    // MARK: - 预乘渐变色标

    func testDenseStopsMatchCSSEndpoints() {
        let stops = WarmLightGlowPalette.denseStops()
        // 两个区间各 25 个采样点，中间边界去重 → 49。
        XCTAssertEqual(stops.count, 49)
        XCTAssertEqual(stops.first?.position ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stops.first?.red ?? 0, 1.0, accuracy: 1e-6)
        XCTAssertEqual(stops.first?.green ?? 0, 207.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(stops.first?.blue ?? 0, 133.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(stops.first?.alpha ?? 0, 143.0 / 255.0, accuracy: 1e-6)

        let second = stops[24]
        XCTAssertEqual(second.position, 0.38, accuracy: 1e-9)
        XCTAssertEqual(second.red, 233.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(second.green, 154.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(second.blue, 87.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(second.alpha, 59.0 / 255.0, accuracy: 1e-6)

        XCTAssertEqual(stops.last?.position ?? -1, 0.70, accuracy: 1e-9)
        XCTAssertEqual(stops.last?.alpha ?? -1, 0, accuracy: 1e-9)
    }

    func testDenseStopsUsePremultipliedInterpolation() {
        let stops = WarmLightGlowPalette.denseStops()
        // 第一段中点（position 0.19）：alpha 为端点均值；颜色比直通插值更亮。
        let mid = stops[12]
        XCTAssertEqual(mid.position, 0.19, accuracy: 1e-9)
        let expectedAlpha = (143.0 / 255.0 + 59.0 / 255.0) / 2
        XCTAssertEqual(mid.alpha, expectedAlpha, accuracy: 1e-4)
        // 预乘中点红 = (255×0.561 + 233×0.231)/2 / alpha ≈ 0.9748（直通插值会得到 0.9569）
        XCTAssertEqual(mid.red, 0.9748, accuracy: 0.002)
        // 透明段颜色保持恒定（premult ÷ alpha 后仍为 E99A57）。
        let fading = stops.first { $0.position > 0.38 && $0.position < 0.70 }!
        XCTAssertEqual(fading.red, 233.0 / 255.0, accuracy: 0.002)
        XCTAssertEqual(fading.green, 154.0 / 255.0, accuracy: 0.002)
    }

    func testDenseStopsPositionsMonotonicAndAlphaNonIncreasing() {
        let stops = WarmLightGlowPalette.denseStops()
        var lastPosition = -1.0
        var lastAlpha = 1.0
        for stop in stops {
            XCTAssertGreaterThan(stop.position, lastPosition - 1e-9)
            XCTAssertLessThanOrEqual(stop.alpha, lastAlpha + 1e-9)
            lastPosition = stop.position
            lastAlpha = stop.alpha
        }
    }
}
