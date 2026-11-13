//
//  WarmLightFrameRenderTests.swift
//  HoloTests
//
//  「一束暖光」离屏渲染对拍（暖光规格 §7.1，替代 App 内调试口子）：
//  - ImageRenderer 在测试内直接渲染暖光叶子（367×336 pt @3x），零 App 入口
//  - 像素级断言：三段文字组水平居中、0ms 纸色角点、1660ms 遮罩完全淡出、减动态亮度
//  - 同时把 8 个关键帧导出 /tmp/holo-warmlight-render/ 供人眼复核
//

import XCTest
import SwiftUI
@testable import Holo

@MainActor
final class WarmLightFrameRenderTests: XCTestCase {

    private let canvasWidth = 367.0
    private let canvasHeight = 336.0
    /// 结果页底色（对拍背板）：浅灰暖底，遮罩淡出后应露出它。
    private let backdrop = (red: 237, green: 232, blue: 235)

    // MARK: - 渲染

    private func render(ms: TimeInterval,
                        dark: Bool = false,
                        reduceMotion: Bool = false) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let departure = MemoryWarmLightTransition.StampContent(
            label: "今天", yearText: "2026 年", dateText: "11 月 13 日", excerpt: nil)
        let arrival = MemoryWarmLightTransition.StampContent(
            label: "想起那一天", yearText: "2026 年", dateText: "5 月 21 日",
            excerpt: "薄荷换盆后，闻起来满手都是薄荷味。")
        let content = ZStack {
            Rectangle().fill(Color(.sRGB,
                                   red: Double(backdrop.red) / 255,
                                   green: Double(backdrop.green) / 255,
                                   blue: Double(backdrop.blue) / 255,
                                   opacity: 1))
            MemoryWarmLightTransition(departure: departure,
                                      arrival: arrival,
                                      timeline: WarmLightTimeline(reduceMotion: reduceMotion),
                                      elapsed: { ms / 1000 })
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer 渲染失败")
        let cg = try XCTUnwrap(image.cgImage)
        return try Self.pixelBytes(of: cg)
    }

    /// CGImage → sRGB RGBA 字节（1× 的 pt 坐标直接乘 3 寻址）。
    private static func pixelBytes(of image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Array(UnsafeBufferPointer(start: data, count: width * height * 4)), width, height)
    }

    private func rgb(_ p: (pixels: [UInt8], width: Int, height: Int), x: Int, y: Int) -> (Int, Int, Int) {
        let i = (y * p.width + x) * 4
        return (Int(p.pixels[i]), Int(p.pixels[i + 1]), Int(p.pixels[i + 2]))
    }

    /// 墨水像素（深棕文字）在行区间内的水平包围盒中心。
    private func inkCenter(_ p: (pixels: [UInt8], width: Int, height: Int),
                           yRange: ClosedRange<Int>) -> (center: Double, count: Int)? {
        var minX = Int.max, maxX = Int.min, count = 0
        for y in yRange {
            for x in 0..<p.width {
                let (r, g, b) = rgb(p, x: x, y: y)
                if r < 160 && g < 130 && b < 120 {
                    minX = min(minX, x); maxX = max(maxX, x); count += 1
                }
            }
        }
        guard count > 20, minX <= maxX else { return nil }
        return (Double(minX + maxX) / 2, count)
    }

    // MARK: - 关键帧导出（人眼复核用）

    func testExportKeyframePNGs() throws {
        let dir = URL(fileURLWithPath: "/tmp/holo-warmlight-render", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for ms in [0, 250, 500, 700, 1000, 1450, 1555, 1660] {
            let departure = MemoryWarmLightTransition.StampContent(
                label: "今天", yearText: "2026 年", dateText: "11 月 13 日", excerpt: nil)
            let arrival = MemoryWarmLightTransition.StampContent(
                label: "想起那一天", yearText: "2026 年", dateText: "5 月 21 日",
                excerpt: "薄荷换盆后，闻起来满手都是薄荷味。")
            let view = ZStack {
                Rectangle().fill(Color(.sRGB, red: 0.929, green: 0.910, blue: 0.922, opacity: 1))
                MemoryWarmLightTransition(departure: departure, arrival: arrival,
                                          timeline: WarmLightTimeline(),
                                          elapsed: { TimeInterval(ms) / 1000 })
            }
            .frame(width: canvasWidth, height: canvasHeight)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: dir.appendingPathComponent("light-\(ms).png"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - 文字组居中（fixedSize 回归防线）

    func testDepartureStampsCenteredAt0ms() throws {
        let frame = try render(ms: 0)
        // 出发组三行：标签/年份区 与 日期区 都应水平居中（±8pt）。
        let labelZone = try XCTUnwrap(inkCenter(frame, yRange: (150*3)...(182*3)))
        XCTAssertLessThan(abs(labelZone.center - 183.5 * 3), 8 * 3, "标签/年份偏移：\(labelZone)")
        let dateZone = try XCTUnwrap(inkCenter(frame, yRange: (183*3)...(210*3)))
        XCTAssertLessThan(abs(dateZone.center - 183.5 * 3), 8 * 3, "日期行偏移：\(dateZone)")
    }

    func testArrivalStampsCenteredAt1000ms() throws {
        let frame = try render(ms: 1000)
        let dateZone = try XCTUnwrap(inkCenter(frame, yRange: (150*3)...(215*3)))
        XCTAssertLessThan(abs(dateZone.center - 183.5 * 3), 8 * 3, "抵达日期行偏移：\(dateZone)")
        let excerptZone = try XCTUnwrap(inkCenter(frame, yRange: (216*3)...(300*3)))
        XCTAssertLessThan(abs(excerptZone.center - 183.5 * 3), 8 * 3, "摘句偏移：\(excerptZone)")
    }

    // MARK: - 颜色与淡出

    func testPaperCornersAt0ms() throws {
        let frame = try render(ms: 0)
        for (x, y) in [(48, 48), (1053, 48), (48, 960), (1053, 960)] {
            let (r, g, b) = rgb(frame, x: x, y: y)
            XCTAssertEqual(abs(r - 248), 0, accuracy: 12, "(\(x),\(y)) r=\(r)")
            XCTAssertEqual(abs(g - 238), 0, accuracy: 12, "(\(x),\(y)) g=\(g)")
            XCTAssertEqual(abs(b - 224), 0, accuracy: 12, "(\(x),\(y)) b=\(b)")
        }
    }

    func testOverlayFullyRevealsBackdropAt1660ms() throws {
        let frame = try render(ms: 1660)
        // 合成层归零：远离圆角的取样板应露出背板色。
        for (x, y) in [(300, 300), (800, 300), (300, 700), (800, 700)] {
            let (r, g, b) = rgb(frame, x: x, y: y)
            XCTAssertEqual(abs(r - backdrop.red), 0, accuracy: 14, "(\(x),\(y)) r=\(r)")
            XCTAssertEqual(abs(g - backdrop.green), 0, accuracy: 14, "(\(x),\(y)) g=\(g)")
            XCTAssertEqual(abs(b - backdrop.blue), 0, accuracy: 14, "(\(x),\(y)) b=\(b)")
        }
    }

    func testReducedMotionGlowAbsentAtStart() throws {
        let normal = try render(ms: 0)
        let reduced = try render(ms: 0, reduceMotion: true)
        // 光的绿通道(207)比纸(238)低：正常 0ms 有 0.18×光 → 光心处绿更低；
        // 减动态 0ms 无光 → 绿通道应回到纸色 238，即高于正常帧。
        let (_, normalG, _) = rgb(normal, x: 550, y: 435)
        let (_, reducedG, _) = rgb(reduced, x: 550, y: 435)
        XCTAssertGreaterThan(reducedG, normalG, "减动态开局不应带光（\(reducedG) vs \(normalG)）")
    }

    // MARK: - 深色可读性（对比度下限）

    func testDarkModeTextReadableAt1000ms() throws {
        let frame = try render(ms: 1000, dark: true)
        // 深色抵达文字奶白 #F9E4CF(249,228,207)：在日期区取最亮像素，应显著亮于底色。
        var maxLuma = 0
        for y in (150*3)..<(215*3) {
            for x in 0..<frame.width {
                let (r, g, b) = rgb(frame, x: x, y: y)
                maxLuma = max(maxLuma, (r + g + b) / 3)
            }
        }
        XCTAssertGreaterThan(maxLuma, 170, "深色模式文字亮度不足：\(maxLuma)")
    }
}
