//
//  HoloInkStrikeTextRenderTests.swift
//  HoloTests
//
//  任务完成「一笔划掉」的渲染对拍（2026-11-23 审美七项 P2）。
//  HoloInkStrikeText 的墨线靠「同排版的透明文字 + 删除线」画出来——文字透明时删除线
//  还画不画得出来，只有真渲染过才知道。这里用 ImageRenderer 实际渲染成位图再数像素，
//  锁死「划掉态有一条横贯的墨线、未划掉态没有」。
//

import SwiftUI
import XCTest
@testable import Holo

@MainActor
final class HoloInkStrikeTextRenderTests: XCTestCase {

    /// 渲染出来的位图（RGBA8，每通道 0…255）
    private struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func isDark(x: Int, y: Int) -> Bool {
            let index = (y * width + x) * 4
            return pixels[index] < 128 && pixels[index + 1] < 128 && pixels[index + 2] < 128
        }

        /// 整幅图里最长的一段「连续深色横线」占图宽的比例
        var longestDarkRunFraction: Double {
            var best = 0
            for y in 0..<height {
                var run = 0
                for x in 0..<width {
                    if isDark(x: x, y: y) {
                        run += 1
                        best = max(best, run)
                    } else {
                        run = 0
                    }
                }
            }
            return Double(best) / Double(max(width, 1))
        }

        /// 某一行里最长的一段「连续深色横线」占图宽的比例
        func longestDarkRunFraction(atY y: Int) -> Double {
            var best = 0
            var run = 0
            for x in 0..<width {
                if isDark(x: x, y: y) {
                    run += 1
                    best = max(best, run)
                } else {
                    run = 0
                }
            }
            return Double(best) / Double(max(width, 1))
        }

        /// 出现过深色横线（连续 ≥ 图宽 40%）的行数：一条墨线大约占 3–5 行
        var lineRowCount: Int {
            (0..<height).filter { longestDarkRunFraction(atY: $0) >= 0.4 }.count
        }
    }

    private func render(isStruck: Bool) throws -> Bitmap {
        // 用字母 M：没有任何横贯整词的横笔画，正文自身不可能连成一条长横线
        let content = HoloInkStrikeText(
            text: "MM MM MM MM",
            isStruck: isStruck,
            font: .system(size: 40, weight: .semibold),
            activeColor: .black,
            doneColor: .black,
            strikeColor: .black,
            lineLimit: 1
        )
        .padding(30)
        .background(Color.white)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "组件应能渲染成位图")
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "位图上下文创建失败")
        return Bitmap(width: width, height: height, pixels: pixels)
    }

    func test_划掉态有一条横贯的墨线() throws {
        let struck = try render(isStruck: true)
        XCTAssertGreaterThanOrEqual(struck.longestDarkRunFraction, 0.5,
                                   "划掉态应有一条横贯文字的墨线，实际最长横线占图宽 \(struck.longestDarkRunFraction)")
        XCTAssertTrue((1...12).contains(struck.lineRowCount), "墨线应是细线（几行像素），实际 \(struck.lineRowCount) 行")
    }

    func test_未划掉态没有横线() throws {
        let plain = try render(isStruck: false)
        XCTAssertLessThan(plain.longestDarkRunFraction, 0.3,
                          "未划掉时正文不应出现横贯的长线，实际 \(plain.longestDarkRunFraction)")
        XCTAssertEqual(plain.lineRowCount, 0, "未划掉时不应有任何一行出现连续长线")
    }
}
