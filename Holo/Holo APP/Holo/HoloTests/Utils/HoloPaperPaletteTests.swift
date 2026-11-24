//
//  HoloPaperPaletteTests.swift
//  HoloTests
//
//  纸色调色板（2026-11-23 审美七项 P6 / P7）。
//  锁三件事：时段边界、四种纸色与两种文字色的对比度下限、泛黄进度与泛黄端点的可读性。
//

import SwiftUI
import XCTest
@testable import Holo

final class HoloPaperPaletteTests: XCTestCase {

    // MARK: - P6 时段边界

    func test_时段边界() {
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 4), .night, "4:59 → 夜")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 5), .morning, "5:00 → 早")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 10), .morning, "10:59 → 早")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 11), .noon, "11:00 → 午")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 16), .noon, "16:59 → 午")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 17), .evening, "17:00 → 傍晚")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 21), .evening, "21:59 → 傍晚")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 22), .night, "22:00 → 夜")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 23), .night, "23 点是夜，不是傍晚")
        XCTAssertEqual(HoloDaylightPeriod.period(forHour: 0), .night, "0 点是夜")
    }

    func test_正午纸色等于现有底色() {
        XCTAssertEqual(HoloPaperPalette.daylightPaperHex(.noon), "FDFCF8")
    }

    func test_四种纸色下的文字对比度() {
        let papers: [HoloDaylightPeriod: String] = [
            .morning: "FDFBF4", .noon: "FDFCF8", .evening: "FAF3E6", .night: "F8F1E3"
        ]
        for (period, hex) in papers {
            XCTAssertEqual(HoloPaperPalette.daylightPaperHex(period), hex)
            XCTAssertGreaterThanOrEqual(HoloPaperPalette.contrastRatio(hex, "6E6E6E"), 4.5,
                                        "\(period) 次要文字对比度")
            XCTAssertGreaterThanOrEqual(HoloPaperPalette.contrastRatio(hex, "333333"), 7,
                                        "\(period) 正文对比度")
        }
    }

    func test_纸色对比度与方案实测值一致() {
        XCTAssertEqual(HoloPaperPalette.contrastRatio("FDFBF4", "6E6E6E"), 4.92, accuracy: 0.02)
        XCTAssertEqual(HoloPaperPalette.contrastRatio("FDFCF8", "6E6E6E"), 4.97, accuracy: 0.02)
        XCTAssertEqual(HoloPaperPalette.contrastRatio("FAF3E6", "6E6E6E"), 4.62, accuracy: 0.02)
        XCTAssertEqual(HoloPaperPalette.contrastRatio("F8F1E3", "6E6E6E"), 4.54, accuracy: 0.02)
    }

    // MARK: - P7 泛黄进度

    func test_泛黄进度端点() {
        XCTAssertEqual(HoloPaperPalette.agingProgress(daysAgo: 0), 0)
        XCTAssertEqual(HoloPaperPalette.agingProgress(daysAgo: 1825), 1)
        XCTAssertEqual(HoloPaperPalette.agingProgress(daysAgo: 4000), 1)
        XCTAssertEqual(HoloPaperPalette.agingProgress(daysAgo: -3), 0, "未来日期不泛黄")
    }

    func test_泛黄进度单调递增() {
        var previous = -1.0
        for days in stride(from: 0, through: 1825, by: 5) {
            let progress = HoloPaperPalette.agingProgress(daysAgo: days)
            XCTAssertGreaterThan(progress, previous, "第 \(days) 天")
            XCTAssertLessThanOrEqual(progress, 1)
            previous = progress
        }
    }

    func test_泛黄进度曲线() {
        XCTAssertEqual(HoloPaperPalette.agingProgress(daysAgo: 365), 0.104, accuracy: 0.005, "一年前约 0.10")
        XCTAssertEqual(HoloPaperPalette.agingProgress(daysAgo: 1095), 0.456, accuracy: 0.005, "三年前约 0.46")
    }

    // MARK: - P7 泛黄后仍可读

    func test_泛黄全程文字对比度() {
        for scheme in [ColorScheme.light, .dark] {
            for progress in [0.0, 0.5, 1.0] {
                let colors = HoloPaperPalette.agedRGB(progress: progress, scheme: scheme)
                XCTAssertGreaterThanOrEqual(HoloPaperPalette.contrastRatio(colors.ink, colors.paper), 4.5,
                                            "\(scheme) progress \(progress) 墨色 × 纸色")
                XCTAssertGreaterThanOrEqual(HoloPaperPalette.contrastRatio(colors.quiet, colors.paper), 4.5,
                                            "\(scheme) progress \(progress) 次要文字 × 纸色")
            }
        }
    }

    func test_泛黄起点等于现状() {
        let light = HoloPaperPalette.agedRGB(progress: 0, scheme: .light)
        XCTAssertEqual(light.paper, HoloPaperPalette.RGB(hex: "FDFCF8"))
        XCTAssertEqual(light.ink, HoloPaperPalette.RGB(hex: "333333"))
        XCTAssertEqual(light.quiet, HoloPaperPalette.RGB(hex: "6E6E6E"))

        let dark = HoloPaperPalette.agedRGB(progress: 0, scheme: .dark)
        XCTAssertEqual(dark.paper, HoloPaperPalette.RGB(hex: "0E0E10"))
        XCTAssertEqual(dark.ink, HoloPaperPalette.RGB(hex: "F5F5F5"))
        XCTAssertEqual(dark.quiet, HoloPaperPalette.RGB(hex: "A8A8A8"))
    }

    func test_泛黄终点对比度与方案实测值一致() {
        let light = HoloPaperPalette.agedRGB(progress: 1, scheme: .light)
        XCTAssertEqual(HoloPaperPalette.contrastRatio(light.ink, light.paper), 6.14, accuracy: 0.02)
        XCTAssertEqual(HoloPaperPalette.contrastRatio(light.quiet, light.paper), 4.93, accuracy: 0.02)
        let dark = HoloPaperPalette.agedRGB(progress: 1, scheme: .dark)
        XCTAssertEqual(HoloPaperPalette.contrastRatio(dark.quiet, dark.paper), 6.54, accuracy: 0.02)
    }
}
