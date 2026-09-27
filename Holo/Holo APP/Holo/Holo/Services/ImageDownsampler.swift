//
//  ImageDownsampler.swift
//  Holo
//
//  大图按像素上限降采样解码。相机原图全尺寸解码位图可达数十至数百MB，
//  是前台内存超限被系统杀死的典型来源；降到显示上限后位图仅数MB。
//

import Foundation
import ImageIO
import UIKit

enum ImageDownsampler {

    /// 从文件直接降采样解码，最长边不超过 maxPixel 像素，解码在后台线程完成。
    static func image(at url: URL, maxPixel: CGFloat = 2_048) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}
