//
//  UserAvatarImageProcessor.swift
//  Holo
//
//  头像图片读取、降采样、裁剪和压缩。输出不保留原图及 EXIF/GPS 元数据。
//

import Foundation
import ImageIO
import UIKit

enum UserAvatarImageProcessor {

    static let preparationMaximumPixelSize = 2_048
    static let outputPixelSize = 512
    static let maximumOutputBytes = 512 * 1_024

    enum ProcessingError: LocalizedError {
        case unreadableImage
        case invalidCrop
        case encodingFailed
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "无法读取这张图片，请换一张试试"
            case .invalidCrop: return "头像裁剪范围无效，请重新调整"
            case .encodingFailed: return "头像处理失败，请重试"
            case .outputTooLarge: return "图片仍然过大，请换一张试试"
            }
        }
    }

    /// 先把相机或相册原图降采样到最长边 2048px，避免在裁剪页完整解码超大照片。
    static func prepareForCropping(_ rawData: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(rawData as CFData, nil) else {
                throw ProcessingError.unreadableImage
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: preparationMaximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ProcessingError.unreadableImage
            }
            guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.94) else {
                throw ProcessingError.encodingFailed
            }
            return data
        }.value
    }

    /// 根据裁剪器给出的归一化方形范围生成 512×512 JPEG。
    static func renderAvatar(
        preparedData: Data,
        selection: UserAvatarCropSelection
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(preparedData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ProcessingError.unreadableImage
            }

            let pixelWidth = CGFloat(image.width)
            let pixelHeight = CGFloat(image.height)
            var cropRect = CGRect(
                x: selection.x * pixelWidth,
                y: selection.y * pixelHeight,
                width: selection.width * pixelWidth,
                height: selection.height * pixelHeight
            ).integral
            cropRect = cropRect.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            guard cropRect.width > 0, cropRect.height > 0,
                  let cropped = image.cropping(to: cropRect) else {
                throw ProcessingError.invalidCrop
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: outputPixelSize, height: outputPixelSize),
                format: format
            )
            let outputImage = renderer.image { context in
                UIColor.white.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: outputPixelSize, height: outputPixelSize))
                UIImage(cgImage: cropped).draw(
                    in: CGRect(x: 0, y: 0, width: outputPixelSize, height: outputPixelSize)
                )
            }

            for quality in stride(from: CGFloat(0.88), through: CGFloat(0.36), by: -0.08) {
                if let data = outputImage.jpegData(compressionQuality: quality), data.count <= maximumOutputBytes {
                    return data
                }
            }
            throw ProcessingError.outputTooLarge
        }.value
    }
}
