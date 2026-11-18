//
//  VisualAssetImageProcessor.swift
//  Holo
//
//  贴纸图像管线 P0：输入规范与纸边合成。
//  - 输入规范：真实格式探测（不信扩展名）、大小上限、ImageIO 降采样（长边 2048，
//    不先全解码大图）、EXIF 方向只应用一次、统一 sRGB、丢弃源元数据（含 GPS）、保留源 alpha。
//  - 纸边合成（02 §3.4）：A = 源 alpha × 占用遮罩；D = dilate(M, r)；R = clamp(D−M, 0, 1)
//    只作外环；纸边在底、主体在上 source-over，最终 alpha = A + R×(1−A)——半透明主体
//    透出纸边而非被整片填白；孔洞直径 > 2r 时中心保持镂空；半径 0 = 不加边（透明 PNG 导入）。
//  规格真源：docs/_common/plans/2026-11-16-Holo贴纸与跨模块视觉素材方案/02-技术落地方案.md §3
//

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreVideo

/// 工作图：管线各阶段的统一载体（sRGB、方向已摆正、长边 ≤ 上限、元数据已丢弃）
struct VisualWorkingImage {
    let cgImage: CGImage
    let hasAlpha: Bool
    var width: Int { cgImage.width }
    var height: Int { cgImage.height }
}

enum VisualAssetImageError: Error, Equatable {
    /// 数据不是可解码的图片（格式探测失败或解码失败）；携带探测到的 UTType 供诊断
    case corruptedOrUnsupported(String?)
    /// 超过初始上限（60MB 编码文件 / 100MP）
    case tooLarge(bytes: Int, megapixels: Double)
}

enum VisualAssetImageProcessor {

    static let maxEncodedBytes = 60 * 1024 * 1024
    static let maxMegapixels = 100.0
    static let workingImageMaxDimension = 2048

    /// 纯 CPU 渲染上下文：算法结果确定性优先（角色级缓存/性能优化属 P2 渲染层）
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - 输入规范

    /// 探测真实 UTType（按数据内容，不按扩展名）
    static func probeUTType(of data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeID = CGImageSourceGetType(source) else { return nil }
        return UTType(typeID as String)
    }

    /// 数据 → 工作图。GIF / 视频由调用方先拦截（本管线只收静态帧）。
    static func prepareWorkingImage(from data: Data) throws -> VisualWorkingImage {
        guard !data.isEmpty else { throw VisualAssetImageError.corruptedOrUnsupported(nil) }
        guard data.count <= maxEncodedBytes else {
            throw VisualAssetImageError.tooLarge(bytes: data.count, megapixels: 0)
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw VisualAssetImageError.corruptedOrUnsupported(probeUTType(of: data)?.identifier)
        }
        // 像素尺寸以真实解码属性为准
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pxW = props[kCGImagePropertyPixelWidth] as? Int,
           let pxH = props[kCGImagePropertyPixelHeight] as? Int {
            let megapixels = Double(pxW * pxH) / 1_000_000
            if megapixels > maxMegapixels {
                throw VisualAssetImageError.tooLarge(bytes: data.count, megapixels: megapixels)
            }
        }
        // 降采样 + EXIF 方向一步完成：WithTransform 按方向摆正，之后管线不再二次应用
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingImageMaxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw VisualAssetImageError.corruptedOrUnsupported(probeUTType(of: data)?.identifier)
        }
        // 重绘到 sRGB：统一色彩空间，同时天然丢弃全部源元数据（含 GPS）
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let alphaInfo = decoded.alphaInfo == .none ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
        let w = decoded.width, h = decoded.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: alphaInfo.rawValue),
              let srgb = { ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.makeImage() }() else {
            throw VisualAssetImageError.corruptedOrUnsupported(nil)
        }
        let hasAlpha = !([.none, .noneSkipLast, .noneSkipFirst] as [CGImageAlphaInfo]).contains(decoded.alphaInfo)
        return VisualWorkingImage(cgImage: srgb, hasAlpha: hasAlpha)
    }

    // MARK: - 纸边合成

    /// 纸边规格：半径已按「角色 pt × displayScale」换算成像素；颜色由 role + 外观在渲染层给出
    struct PaperEdgeSpec {
        var radiusPixels: CGFloat
        var color: CGColor
        /// 不加纸边（透明 PNG 导入默认；「无纸边」用户选择）
        static let none = PaperEdgeSpec(radiusPixels: 0, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0))
    }

    /// 合成贴纸：纸边环在底、主体在上。输出 extent 外扩（半径向上取整 + 1px 安全余量）。
    /// - Parameters:
    ///   - subject: 摆正后的工作图（可带 alpha）
    ///   - occupancyMask: OneComponent8 灰度占用遮罩，尺寸必须与 subject 一致
    static func composeSticker(subject: CGImage,
                               occupancyMask: CVPixelBuffer,
                               edge: PaperEdgeSpec) -> CGImage {
        let subjectCI = CIImage(cgImage: subject)
        let maskCI = CIImage(cvPixelBuffer: occupancyMask).cropped(to: subjectCI.extent)
        let pad = ceil(edge.radiusPixels) + 1
        let baseExtent = subjectCI.extent.insetBy(dx: -pad, dy: -pad)
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: baseExtent)

        // 主体层：CIBlendWithMask 的 mask 同时作用于 RGB 与 alpha，
        // outA = 源 alpha × M = A ——正是 02 §3.4 的 A 定义
        let subjectLayer = blend(input: subjectCI, background: transparent, mask: maskCI)

        guard edge.radiusPixels > 0 else {
            // 半径 0：D = M → R = 0，无纸边，直接返回主体层
            return render(subjectLayer, from: subjectCI.extent)
        }

        // 先把 mask 补黑边扩到 baseExtent，确保紧裁贴纸触及边界的轮廓也能向外长出完整纸边
        let blackPad = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: baseExtent)
        let paddedMask = maskCI.composited(over: blackPad).cropped(to: baseExtent)

        // D = dilate(M, r)；R = D × (1 − M) 只在占用边界的外环上非零
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = paddedMask
        dilate.radius = Float(edge.radiusPixels)
        let dilated = output(dilate).cropped(to: baseExtent)

        let invert = CIFilter.colorMatrix()
        invert.inputImage = paddedMask
        invert.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
        invert.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        invert.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
        // alpha 恒 1：CI 图像按预乘语义传递，alpha 反转成 0 会把已算好的 rgb 归零丢弃
        invert.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        invert.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        let invM = output(invert).cropped(to: baseExtent)

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = invM
        multiply.backgroundImage = dilated
        let ring = output(multiply).cropped(to: baseExtent)

        // 纸边层 = 纸边色 × R；主体在上 source-over：最终 alpha = A + R×(1−A)
        // 外部传入的 CGColor 可能未指定空间（GenericRGB 宽色域会导致纯色串色），统一转到 sRGB
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let edgeCGColor = edge.color.converted(to: srgbSpace, intent: .defaultIntent, options: nil) ?? edge.color
        let edgeColor = CIImage(color: CIColor(cgColor: edgeCGColor) ?? CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: baseExtent)
        let paperLayer = blend(input: edgeColor, background: transparent, mask: ring)
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = subjectLayer
        over.backgroundImage = paperLayer
        let composite = output(over).cropped(to: baseExtent)
        return render(composite, from: baseExtent)
    }

    /// 透明 PNG 导入的占用遮罩：alpha > 1/255 计为占用（02 §3.4：不按白色 RGB 抠图），
    /// 边缘抗锯齿由 alpha 渐变天然提供
    static func occupancyMask(fromAlphaOf image: CGImage) -> CVPixelBuffer? {
        let w = image.width, h = image.height
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard let pb = buffer else { return nil }
        // 2026-11-19 二次根治：上一版把 Swift 数组的 & 指针直接交给 CGContext(data:)——
        // 指针在调用后失效属未定义行为（单测实测 malloc 崩：pointer being freed was not
        // allocated；透明 PNG 直通路径每次都踩）。改显式堆分配 + 手动释放，杜绝悬垂
        let bytesPerRow = w * 4
        let rgbaBuffer = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * h, alignment: 64)
        guard let ctx = CGContext(data: rgbaBuffer, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            rgbaBuffer.deallocate()
            return pb
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rgba = rgbaBuffer.assumingMemoryBound(to: UInt8.self)
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
            let dstRowBytes = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<h {
                let srcRow = y * bytesPerRow
                let dstRow = y * dstRowBytes
                for x in 0..<w {
                    base[dstRow + x] = rgba[srcRow + x * 4 + 3]
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        rgbaBuffer.deallocate()
        return pb
    }

    // MARK: - 存储字段解码（渲染层用）

    /// sourceData/contentData 已是工作图规范（sRGB、方向摆正、长边 ≤2048），
    /// 直接解码不再走方向/降采样（避免二次变换）
    static func decodeWorkingCGImage(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// maskData（8bit 灰度 PNG，工作画布尺寸）→ OneComponent8 像素缓冲
    static func decodeMask(from data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        guard let cg = decodeWorkingCGImage(from: data) else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height,
                            kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard let pb = buffer else { return nil }
        ciContext.render(CIImage(cgImage: cg), to: pb,
                         bounds: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
                         colorSpace: CGColorSpaceCreateDeviceGray())
        return pb
    }

    /// photo 派生：等比降采样到目标长边（不放大——源小于目标时原样返回）。
    /// 2026-11-18 根治：旧写法 `scale.rounded(.up)` 把缩小系数（如 0.21）向上取整成 1，
    /// 本函数从未真正缩小过任何图——图标位单张 ~9.4MB 内存爆仓的真正源头
    static func downscale(_ image: CGImage, targetLongest: CGFloat) -> CGImage {
        let longest = max(image.width, image.height)
        guard CGFloat(longest) > targetLongest, targetLongest > 0 else { return image }
        let scale = targetLongest / CGFloat(longest)
        let w = max(1, Int((CGFloat(image.width) * scale).rounded(.up)))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded(.up)))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// photo 夜间柔光：深色预览 RGB×0.92、alpha 不变；只影响预览，不改源文件（04 §5.2）
    static func softenPhoto(_ image: CGImage, targetLongest: CGFloat) -> CGImage {
        let base = downscale(image, targetLongest: targetLongest)
        let ci = CIImage(cgImage: base)
        let f = CIFilter.colorMatrix()
        f.inputImage = ci
        f.rVector = CIVector(x: 0.92, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: 0.92, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: 0.92, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let out = f.outputImage,
              let cg = ciContext.createCGImage(out, from: out.extent) else { return base }
        return cg
    }

    // MARK: - 存储编码（制作页提交用）

    /// CGImage → PNG Data（透明保留；工作图/紧裁主体/缩略图共用）
    static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// OneComponent8 遮罩 → 灰度 PNG（恢复时按工作画布尺寸解码）
    static func encodeMaskPNG(_ mask: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: mask)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return encodePNG(cg)
    }

    /// 紧裁主体（sticker 的 contentData）：mask 非零区的 bounding box 裁切 + 长边限幅
    static func tightCrop(_ image: CGImage, mask: CVPixelBuffer, maxLongest: Int) -> CGImage? {
        tightCropWithMask(image, mask: mask, maxLongest: maxLongest)?.image
    }

    /// 紧裁主体并同步裁剪缩放 mask，保证 contentData 与 maskData 尺寸和像素一一对应
    static func tightCropWithMask(_ image: CGImage, mask: CVPixelBuffer, maxLongest: Int) -> (image: CGImage, mask: CVPixelBuffer)? {
        let mask8 = ensureOneComponent8(mask)
        CVPixelBufferLockBaseAddress(mask8, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask8, .readOnly) }
        let w = CVPixelBufferGetWidth(mask8), h = CVPixelBufferGetHeight(mask8)
        guard w == image.width, h == image.height,
              let base = CVPixelBufferGetBaseAddress(mask8)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(mask8)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = base + y * rowBytes
            for x in 0..<w where row[x] > 1 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let cropW = maxX - minX + 1
        let cropH = maxY - minY + 1
        let cropRect = CGRect(x: minX, y: minY, width: cropW, height: cropH)
        let cropped = image.cropping(to: cropRect) ?? image

        var croppedMaskBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, cropW, cropH, kCVPixelFormatType_OneComponent8, nil, &croppedMaskBuffer)
        guard let croppedMask = croppedMaskBuffer else { return nil }
        CVPixelBufferLockBaseAddress(croppedMask, [])
        if let dstBase = CVPixelBufferGetBaseAddress(croppedMask)?.assumingMemoryBound(to: UInt8.self) {
            let dstRowBytes = CVPixelBufferGetBytesPerRow(croppedMask)
            for y in 0..<cropH {
                memcpy(dstBase + y * dstRowBytes, base + (minY + y) * rowBytes + minX, cropW)
            }
        }
        CVPixelBufferUnlockBaseAddress(croppedMask, [])

        let longest = max(cropped.width, cropped.height)
        guard longest > maxLongest else { return (cropped, croppedMask) }
        let scaledImage = downscale(cropped, targetLongest: CGFloat(maxLongest))
        guard let scaledMask = downscaleMask(croppedMask, width: scaledImage.width, height: scaledImage.height) else {
            return nil
        }
        return (scaledImage, scaledMask)
    }

    /// 遮罩同步降采样（渲染层先降采样再合成纸边时与画面同步缩放）
    static func downscaleMask(_ mask: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard let dst = buffer else { return nil }
        let srcW = CVPixelBufferGetWidth(mask)
        let srcH = CVPixelBufferGetHeight(mask)
        guard srcW > 0, srcH > 0 else { return nil }
        let scaleX = CGFloat(width) / CGFloat(srcW)
        let scaleY = CGFloat(height) / CGFloat(srcH)
        let ci = CIImage(cvPixelBuffer: mask).transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(ci, to: dst, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpaceCreateDeviceGray())
        return dst
    }

    private static func ensureOneComponent8(_ mask: CVPixelBuffer) -> CVPixelBuffer {
        if CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 {
            return mask
        }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard let dst = buffer else { return mask }
        ciContext.render(CIImage(cvPixelBuffer: mask), to: dst,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         colorSpace: CGColorSpaceCreateDeviceGray())
        return dst
    }

    // MARK: - 私有

    private static func blend(input: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = input
        f.backgroundImage = background
        f.maskImage = mask
        return output(f)
    }

    /// CIFilter 输出解包：输入已构造完整时 outputImage 不为空，空即管线环境异常——尽早暴露
    private static func output(_ filter: CIFilter) -> CIImage {
        guard let image = filter.outputImage else {
            fatalError("CIFilter 无输出：\(filter.name)")
        }
        return image
    }

    private static func render(_ image: CIImage, from extent: CGRect) -> CGImage {
        guard let cg = ciContext.createCGImage(image, from: extent) else {
            fatalError("CI 渲染失败 extent=\(extent)")
        }
        return cg
    }
}
