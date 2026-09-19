//
//  UserAvatarCropState.swift
//  Holo
//
//  头像裁剪的纯几何契约，可脱离 SwiftUI 做断言验证。
//

import CoreGraphics

struct UserAvatarCropSelection: Sendable, Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var normalizedRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum UserAvatarCropGeometry {

    static let minimumZoom: CGFloat = 1
    static let maximumZoom: CGFloat = 6

    static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoom), maximumZoom)
    }

    static func baseScale(imageSize: CGSize, viewportSide: CGFloat) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewportSide > 0 else { return 1 }
        return max(viewportSide / imageSize.width, viewportSide / imageSize.height)
    }

    static func displayedSize(imageSize: CGSize, viewportSide: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = baseScale(imageSize: imageSize, viewportSide: viewportSide) * clampedZoom(zoom)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func clampedOffset(
        _ proposed: CGSize,
        imageSize: CGSize,
        viewportSide: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let displayed = displayedSize(imageSize: imageSize, viewportSide: viewportSide, zoom: zoom)
        let maxX = max(0, (displayed.width - viewportSide) / 2)
        let maxY = max(0, (displayed.height - viewportSide) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    static func selection(
        imageSize: CGSize,
        viewportSide: CGFloat,
        zoom: CGFloat,
        offset: CGSize
    ) -> UserAvatarCropSelection {
        guard imageSize.width > 0, imageSize.height > 0, viewportSide > 0 else {
            return UserAvatarCropSelection(x: 0, y: 0, width: 1, height: 1)
        }

        let safeZoom = clampedZoom(zoom)
        let scale = baseScale(imageSize: imageSize, viewportSide: viewportSide) * safeZoom
        let safeOffset = clampedOffset(
            offset,
            imageSize: imageSize,
            viewportSide: viewportSide,
            zoom: safeZoom
        )
        let cropSide = viewportSide / scale
        let originX = (imageSize.width / 2) - (cropSide / 2) - (safeOffset.width / scale)
        let originY = (imageSize.height / 2) - (cropSide / 2) - (safeOffset.height / scale)

        return UserAvatarCropSelection(
            x: min(max(originX / imageSize.width, 0), 1),
            y: min(max(originY / imageSize.height, 0), 1),
            width: min(max(cropSide / imageSize.width, 0), 1),
            height: min(max(cropSide / imageSize.height, 0), 1)
        )
    }
}
