//
//  ThoughtShareCardPolaroidLayoutTests.swift
//  Holo
//  拍立得槽位钳制回归：竖图 fill 后不得撑爆槽位、白框不得盖住正文区。
//  竖图卡(P)与横图卡(L)版面坐标完全同源（正文/槽位不依赖图片宽高比），
//  健康实现下两张导出图在「首张拍立得上缘」之上的每一行像素必须逐位一致；
//  竖图一旦溢出槽位向上，P 会先于 L 出现白色相框边缘 → 该断言即红。
//

import XCTest
@testable import Holo

final class ThoughtShareCardPolaroidLayoutTests: XCTestCase {

    private let artifactDir = URL(fileURLWithPath: "/tmp/holo_sharecard_polaroid")

    // MARK: 用例

    @MainActor
    func testPortraitPhotoClampedIntoSlot_textZoneUntouched() throws {
        // 极端竖图是历史事故源（白框向上盖正文第二行）；横图作对照组
        let portraitPhotos = (0..<5).map { Self.solidPhoto(index: $0, size: CGSize(width: 500, height: 2000)) }
        let landscapePhotos = (0..<5).map { Self.solidPhoto(index: $0, size: CGSize(width: 1000, height: 500)) }

        let cardP = Self.makeCard(photos: portraitPhotos)
        let cardL = Self.makeCard(photos: landscapePhotos)

        let imageP = try XCTUnwrap(ThoughtShareCard.renderExportImage(cardP))
        let imageL = try XCTUnwrap(ThoughtShareCard.renderExportImage(cardL))

        try saveArtifact(imageP, name: "portrait.png")
        try saveArtifact(imageL, name: "landscape.png")

        // 卡宽固定：3x 导出 1020px（末行杂色线已被导出链路裁掉）
        XCTAssertEqual(Int(imageP.size.width * imageP.scale), Int(ThoughtShareCard.cardWidth * 3))

        let bitmapP = try XCTUnwrap(Self.rgbaBitmap(imageP))
        let bitmapL = try XCTUnwrap(Self.rgbaBitmap(imageL))
        XCTAssertEqual(bitmapP.pixels.count, bitmapL.pixels.count, "两张导出图尺寸应一致")

        let photoTopL = try XCTUnwrap(Self.firstWhiteFrameRow(bitmap: bitmapL))
        let photoTopP = try XCTUnwrap(Self.firstWhiteFrameRow(bitmap: bitmapP))
        // 竖图白框一旦向上溢出，P 的相框上缘会早于 L 出现
        XCTAssertGreaterThanOrEqual(
            photoTopP, photoTopL,
            "竖图卡拍立得上缘不得高于横图卡（=竖图撑爆槽位向上溢出）"
        )

        // 正文区（首张相框上缘之上）必须逐位一致：照片不得画进文字
        for row in 0..<photoTopL {
            let base = row * bitmapL.width * 4
            for byte in base..<(base + bitmapL.width * 4) {
                if bitmapP.pixels[byte] != bitmapL.pixels[byte] {
                    XCTFail("第 \(row) 行（正文区，首张相框上缘在 \(photoTopL)）像素不一致：照片溢出盖住了文字")
                    return
                }
            }
        }
    }

    // MARK: 造数

    @MainActor
    private static func makeCard(photos: [ThoughtShareCardPhoto]) -> ThoughtShareCard {
        ThoughtShareCard(
            contentNodes: [.text(value: "几年没来东京了，又一次登上了 shibuya sky 的观景台，这次的天气比上次好得多，整座城市在傍晚亮起灯来。")],
            attachments: photos,
            tagNames: ["东京", "旅行"],
            moodLabel: "开心",
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            authorName: "东林"
        )
    }

    /// 纯色合成图：颜色按序号区分，竖图/横图钳进同一槽位后应渲染出同色块
    @MainActor
    private static func solidPhoto(index: Int, size: CGSize) -> ThoughtShareCardPhoto {
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.85, 0.32, 0.12), (0.16, 0.35, 0.58), (0.24, 0.55, 0.30),
            (0.55, 0.42, 0.65), (0.80, 0.62, 0.18),
        ]
        let color = palette[index % palette.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: color.0, green: color.1, blue: color.2, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return ThoughtShareCardPhoto(id: UUID(), image: image)
    }

    // MARK: 位图工具

    private func saveArtifact(_ image: UIImage, name: String) throws {
        try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let url = artifactDir.appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[ShareCardPolaroid] artifact \(url.path)")
    }

    private struct Bitmap {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// UIImage → RGBA8 字节缓冲
    private static func rgbaBitmap(_ image: UIImage) -> Bitmap? {
        guard let cg = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(
            data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Bitmap(pixels: pixels, width: cg.width, height: cg.height)
    }

    /// 首个「拍立得白框」行：一行内出现 ≥60 连续像素近乎纯白（纸底 b≈240，白框 ≥252，可区分）。
    /// 相框带 ±2.2° 微旋转，上缘为斜边，取该行即可。
    private static func firstWhiteFrameRow(bitmap: Bitmap) -> Int? {
        var run = 0
        for row in 0..<bitmap.height {
            run = 0
            for col in 0..<bitmap.width {
                let i = (row * bitmap.width + col) * 4
                let isWhite = bitmap.pixels[i] >= 252 && bitmap.pixels[i + 1] >= 252 && bitmap.pixels[i + 2] >= 252
                run = isWhite ? run + 1 : 0
                if run >= 60 { return row }
            }
        }
        return nil
    }
}
