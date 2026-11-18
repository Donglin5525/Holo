//
//  VisualAssetImageProcessorTests.swift
//  HoloTests
//
//  贴纸图像管线 P0 算法测试：全部用程序合成图（无照片依赖），锁死 02 §3 的数学契约——
//  A + R×(1−A) 合成、R 只在占用外环、半透明不被整片填白、孔洞保留、方向只应用一次、
//  元数据丢弃、上限拒绝、透明 PNG 零半径不加边。
//  对应验收场景：S08（HEIC 方向）、S17（alpha 边缘夹具）、N07（孔洞/细线）。
//
//  坑（实测踩过，勿回退）：CGColor(red:...) 不带空间参数默认 GenericRGB 宽色域，
//  纯红 fill 进 sRGB 位图会串色（g≈38/255）——夹具颜色一律走 srgb() helper 显式指定空间。
//  composeSticker 输出 extent 外扩 pad = ceil(radius)+1，采样坐标必须加 pad 偏移。
//

import XCTest
@testable import Holo
import CoreGraphics
import ImageIO
import CoreVideo
import UniformTypeIdentifiers

final class VisualAssetImageProcessorTests: XCTestCase {

    // MARK: - 测试工具

    private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(colorSpace: srgbSpace, components: [r, g, b, a])!
    }

    private func makeImage(width: Int, height: Int, hasAlpha: Bool = true, draw: (CGContext) -> Void) -> CGImage {
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                            : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: srgbSpace, bitmapInfo: info)!
        draw(ctx)
        return ctx.makeImage()!
    }

    /// OneComponent8 占用遮罩；occupancy 返回 0…1
    private func makeMask(width: Int, height: Int, occupancy: (Int, Int) -> Double) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_OneComponent8, nil, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            for x in 0..<width {
                base[y * rowBytes + x] = UInt8(max(0, min(1, occupancy(x, y))) * 255)
            }
        }
        return pb
    }

    /// 读指定像素（自 CI 渲染输出；测试图案左右布局，取中线不受行序翻转影响）
    private func rgba(of image: CGImage, at x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: srgbSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(y),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private func jpegData(of image: CGImage, properties: [CFString: Any] = [:]) -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            fatalError("JPEG destination 创建失败")
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private let edgeGreen = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    components: [0, 1, 0, 1])!
    private let edgeRadius: CGFloat = 10
    /// composeSticker 输出相对输入的坐标偏移 = ceil(radius) + 1
    private var pad: Int { Int(ceil(edgeRadius)) + 1 }

    /// 标准合成夹具：左半不透明红主体，右半全透明；遮罩同形
    private func leftRightFixture(width: Int = 200, height: Int = 100, subjectAlpha: CGFloat = 1) -> (subject: CGImage, mask: CVPixelBuffer) {
        let subject = makeImage(width: width, height: height) { ctx in
            ctx.setFillColor(self.srgb(1, 0, 0, subjectAlpha))
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        let mask = makeMask(width: width, height: height) { x, _ in x < width / 2 ? 1 : 0 }
        return (subject, mask)
    }

    // MARK: - 输入规范

    func testProbeRealFormatIgnoresExtension() {
        let png = makeImage(width: 4, height: 4, hasAlpha: true) { _ in }
        let data = png.pngDataForTesting()
        let type = VisualAssetImageProcessor.probeUTType(of: data)
        XCTAssertEqual(type?.identifier, UTType.png.identifier)
    }

    func testRejectsOversizeEncodedBytes() {
        let huge = Data(count: VisualAssetImageProcessor.maxEncodedBytes + 1)
        XCTAssertThrowsError(try VisualAssetImageProcessor.prepareWorkingImage(from: huge)) { error in
            guard case VisualAssetImageError.tooLarge = error else {
                return XCTFail("应抛 tooLarge，实际 \(error)")
            }
        }
    }

    func testDownsamplesTo2048AndAppliesOrientationOnce() throws {
        // 4000×3000 + EXIF orientation 6（顺时针 90°）→ 摆正后 3000×4000 → 长边压到 2048
        let raw = makeImage(width: 4000, height: 3000, hasAlpha: false) { ctx in
            ctx.setFillColor(self.srgb(0.5, 0.5, 0.5, 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let jpeg = jpegData(of: raw, properties: [kCGImagePropertyOrientation: 6])
        let working = try VisualAssetImageProcessor.prepareWorkingImage(from: jpeg)
        XCTAssertEqual(working.width, 1536)
        XCTAssertEqual(working.height, 2048)
        XCTAssertFalse(working.hasAlpha)
    }

    func testMetadataGPSStripped() throws {
        let raw = makeImage(width: 20, height: 20, hasAlpha: false) { ctx in
            ctx.setFillColor(self.srgb(0.2, 0.4, 0.6, 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 39.9, kCGImagePropertyGPSLatitudeRef: "N"]
        let jpeg = jpegData(of: raw, properties: [kCGImagePropertyGPSDictionary: gps])
        let working = try VisualAssetImageProcessor.prepareWorkingImage(from: jpeg)
        // 工作图重编码后不得再携带 GPS
        let png = working.cgImage.pngDataForTesting()
        let src = CGImageSourceCreateWithData(png as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary])
    }

    func testAlphaFlagsFollowSource() throws {
        let transparent = makeImage(width: 8, height: 8, hasAlpha: true) { ctx in
            ctx.setFillColor(self.srgb(1, 0, 0, 0.5))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let w1 = try VisualAssetImageProcessor.prepareWorkingImage(from: transparent.pngDataForTesting())
        XCTAssertTrue(w1.hasAlpha)

        let opaque = makeImage(width: 8, height: 8, hasAlpha: false) { ctx in
            ctx.setFillColor(self.srgb(0, 0, 1, 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let w2 = try VisualAssetImageProcessor.prepareWorkingImage(from: jpegData(of: opaque))
        XCTAssertFalse(w2.hasAlpha)
    }

    // MARK: - 纸边合成数学（02 §3.4 / 验收 S17、N07）

    func testPaperEdgeCompositeMath() {
        let fixture = leftRightFixture()
        let out = VisualAssetImageProcessor.composeSticker(
            subject: fixture.subject, occupancyMask: fixture.mask,
            edge: .init(radiusPixels: edgeRadius, color: edgeGreen))
        let midY = out.height / 2

        // 主体内部（输入 x=30）：不透明纯红（A=1 → R 不影响）
        let inside = rgba(of: out, at: 30 + pad, midY)
        XCTAssertEqual(Double(inside.a), 255, accuracy: 3)
        XCTAssertEqual(Double(inside.r), 255, accuracy: 3)
        XCTAssertLessThan(Int(inside.g), 10)

        // 主体内近边界（输入 x=95，M=1）：D−M=0 → 无纸边混入，仍为红
        let nearEdgeInside = rgba(of: out, at: 95 + pad, midY)
        XCTAssertGreaterThan(Int(nearEdgeInside.r), 245)
        XCTAssertLessThan(Int(nearEdgeInside.g), 20)

        // 环内（输入 x=104，M=0、R=1）：纯纸边绿
        let ring = rgba(of: out, at: 104 + pad, midY)
        XCTAssertEqual(Double(ring.a), 255, accuracy: 3)
        XCTAssertGreaterThan(Int(ring.g), 245)

        // 远背景（输入 x=130，距主体 > r）：R=0 → 全透明，纸边不外溢
        let far = rgba(of: out, at: 130 + pad, midY)
        XCTAssertLessThan(Int(far.a), 6)
    }

    func testSemiTransparentSubjectNotFilledByPaper() {
        // 玻璃场景：主体 alpha=0.5 —— A=0.5、M=1 处 R=0，最终 alpha 仍是 0.5（不被纸边填白）
        let fixture = leftRightFixture(subjectAlpha: 0.5)
        let out = VisualAssetImageProcessor.composeSticker(
            subject: fixture.subject, occupancyMask: fixture.mask,
            edge: .init(radiusPixels: edgeRadius, color: edgeGreen))
        let center = rgba(of: out, at: 50 + pad, out.height / 2)
        XCTAssertEqual(Double(center.a), 128, accuracy: 6)
        // 环上（输入 x=104）：alpha = 0 + R×(1−0) = R，纸边以自身强度透出
        let ring = rgba(of: out, at: 104 + pad, out.height / 2)
        XCTAssertEqual(Double(ring.a), 255, accuracy: 6)
    }

    func testHoleWiderThanEdgeStaysOpen() {
        // 全图为主体，中心开直径 60 的孔；边半径 10 → 孔中心距孔壁 30 > 10，保持镂空
        let subject = makeImage(width: 200, height: 200) { ctx in
            ctx.setFillColor(self.srgb(0, 0, 1, 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: 70, y: 70, width: 60, height: 60))
        }
        let mask = makeMask(width: 200, height: 200) { x, y in
            let dx = Double(x) - 100, dy = Double(y) - 100
            return (dx * dx + dy * dy) <= 30 * 30 ? 0 : 1
        }
        let out = VisualAssetImageProcessor.composeSticker(
            subject: subject, occupancyMask: mask,
            edge: .init(radiusPixels: edgeRadius, color: edgeGreen))
        let holeCenter = rgba(of: out, at: 100 + pad, 100 + pad)
        XCTAssertLessThan(Int(holeCenter.a), 6, "孔洞中心应保持镂空（N07：外环不填整主体）")
        // 孔壁向内 r 的环上应有纸边（厚边自然收窄孔缘）
        let holeRim = rgba(of: out, at: 100 + pad, 75 + pad)
        XCTAssertGreaterThan(Int(holeRim.a), 100, "孔边缘 r 内应有纸边环")
    }

    func testZeroRadiusAddsNoEdge() {
        // 透明 PNG 导入契约：默认不加第二层纸边（提前返回，无 pad）
        let fixture = leftRightFixture()
        let out = VisualAssetImageProcessor.composeSticker(
            subject: fixture.subject, occupancyMask: fixture.mask, edge: .none)
        XCTAssertEqual(out.width, fixture.subject.width)
        XCTAssertEqual(out.height, fixture.subject.height)
        let inside = rgba(of: out, at: 50, out.height / 2)
        XCTAssertEqual(Double(inside.a), 255, accuracy: 3)
        XCTAssertEqual(Double(inside.r), 255, accuracy: 3)
        let outside = rgba(of: out, at: 150, out.height / 2)
        XCTAssertLessThan(Int(outside.a), 6)
    }

    func testOutputExtentPaddedBeyondSubject() {
        let fixture = leftRightFixture()
        let out = VisualAssetImageProcessor.composeSticker(
            subject: fixture.subject, occupancyMask: fixture.mask,
            edge: .init(radiusPixels: edgeRadius, color: edgeGreen))
        let expectedPad = Int(ceil(edgeRadius)) + 1
        XCTAssertEqual(out.width, fixture.subject.width + expectedPad * 2)
        XCTAssertEqual(out.height, fixture.subject.height + expectedPad * 2)
    }

    func testTightCropWithMaskKeepsContentAndMaskAligned() {
        // 11-17 回归锁：偏心主体紧裁时 content 与 mask 必须同步裁剪，否则渲染时 mask 错位导致贴纸全透明
        let size = 100
        let subject = makeImage(width: size, height: size) { ctx in
            ctx.setFillColor(self.srgb(0.86, 0.31, 0.24, 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        let mask = makeMask(width: size, height: size) { x, y in
            (x >= 40 && x < 60 && y >= 30 && y < 60) ? 1 : 0
        }
        guard let cropped = VisualAssetImageProcessor.tightCropWithMask(subject, mask: mask, maxLongest: 1536) else {
            return XCTFail("tightCropWithMask 不应返回 nil")
        }
        XCTAssertEqual(cropped.image.width, 20)
        XCTAssertEqual(cropped.image.height, 30)
        XCTAssertEqual(CVPixelBufferGetWidth(cropped.mask), 20)
        XCTAssertEqual(CVPixelBufferGetHeight(cropped.mask), 30)

        let out = VisualAssetImageProcessor.composeSticker(
            subject: cropped.image, occupancyMask: cropped.mask, edge: .none)
        let center = rgba(of: out, at: 10, 15)
        XCTAssertGreaterThan(Int(center.a), 200, "同步裁剪后的中心像素应不透明")
    }

    func testFloat32MaskFromVisionNormalizesAndTightCropsWithoutShear() {
        // 11-17 回归锁：Vision generateScaledMaskForImage 返回 OneComponent32Float（4 字节/像素），
        // tightCropWithMask 必须先转 OneComponent8 再按 1 字节步长读取，否则发生对角错切
        let w = 120, h = 100
        let subject = makeImage(width: w, height: h) { ctx in
            ctx.setFillColor(self.srgb(0.2, 0.7, 0.4, 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        var floatBuf: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent32Float, nil, &floatBuf)
        let fpb = floatBuf!
        CVPixelBufferLockBaseAddress(fpb, [])
        let base = CVPixelBufferGetBaseAddress(fpb)!
        let rowBytes = CVPixelBufferGetBytesPerRow(fpb)
        for y in 0..<h {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                row[x] = (x >= 30 && x < 70 && y >= 20 && y < 60) ? 1.0 : 0.0
            }
        }
        CVPixelBufferUnlockBaseAddress(fpb, [])

        guard let cropped = VisualAssetImageProcessor.tightCropWithMask(subject, mask: fpb, maxLongest: 1536) else {
            return XCTFail("Float32 mask 必须能正常紧裁")
        }
        XCTAssertEqual(cropped.image.width, 40)
        XCTAssertEqual(cropped.image.height, 40)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(cropped.mask), kCVPixelFormatType_OneComponent8)
        XCTAssertEqual(CVPixelBufferGetWidth(cropped.mask), 40)
        XCTAssertEqual(CVPixelBufferGetHeight(cropped.mask), 40)

        let out = VisualAssetImageProcessor.composeSticker(
            subject: cropped.image, occupancyMask: cropped.mask, edge: .none)
        let center = rgba(of: out, at: 20, 20)
        XCTAssertGreaterThan(Int(center.a), 240, "紧裁后主体中心必须完整不透明且无错切")
    }

    func testTightCropWithMaskDownscalesLargeCroppedSubimageAligned() {
        // 11-17 回归锁：模拟 recrop 生成的子 CGImage 且超过 maxLongest(1536) 时，
        // 图像与 mask 等比缩放到完全相同尺寸且中心像素不透明
        let full = makeImage(width: 2000, height: 2000) { ctx in
            ctx.setFillColor(self.srgb(0.9, 0.3, 0.2, 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 2000))
        }
        let recropped = full.cropping(to: CGRect(x: 100, y: 100, width: 1800, height: 1800))!
        let mask = makeMask(width: 1800, height: 1800) { x, y in
            (x >= 50 && x < 1750 && y >= 50 && y < 1750) ? 1 : 0
        }
        guard let tight = VisualAssetImageProcessor.tightCropWithMask(recropped, mask: mask, maxLongest: 1536) else {
            return XCTFail("大图紧裁降采样不应返回 nil")
        }
        XCTAssertEqual(tight.image.width, 1536)
        XCTAssertEqual(tight.image.height, 1536)
        XCTAssertEqual(CVPixelBufferGetWidth(tight.mask), 1536)
        XCTAssertEqual(CVPixelBufferGetHeight(tight.mask), 1536)

        let out = VisualAssetImageProcessor.composeSticker(
            subject: tight.image, occupancyMask: tight.mask, edge: .none)
        let center = rgba(of: out, at: 768, 768)
        XCTAssertGreaterThan(Int(center.a), 240, "降采样后主体中心必须完整不透明")
    }
}

// MARK: - 测试辅助

private extension CGImage {
    /// PNG 编码（测试内使用；与产品编码路径无关）
    func pngDataForTesting() -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, self, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
