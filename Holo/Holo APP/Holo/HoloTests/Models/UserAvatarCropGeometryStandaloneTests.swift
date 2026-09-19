//
//  UserAvatarCropGeometryStandaloneTests.swift
//  Holo
//
//  运行：
//    swiftc Holo/Models/UserAvatarCropState.swift \
//      HoloTests/Models/UserAvatarCropGeometryStandaloneTests.swift \
//      -o /tmp/user-avatar-crop-tests && /tmp/user-avatar-crop-tests
//

import CoreGraphics
import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() {
        UserAvatarCropGeometryStandaloneTests.main()
    }
}
#endif

struct UserAvatarCropGeometryStandaloneTests {

    static func main() {
        let landscape = CGSize(width: 4_000, height: 2_000)
        let centeredLandscape = UserAvatarCropGeometry.selection(
            imageSize: landscape,
            viewportSide: 300,
            zoom: 1,
            offset: .zero
        )
        expectApproximately(centeredLandscape.x, 0.25, "横图默认裁剪应居中")
        expectApproximately(centeredLandscape.y, 0, "横图默认裁剪应覆盖完整高度")
        expectApproximately(centeredLandscape.width, 0.5, "横图默认裁剪为中央正方形")
        expectApproximately(centeredLandscape.height, 1, "横图默认裁剪高度为 100%")

        let portrait = CGSize(width: 2_000, height: 4_000)
        let centeredPortrait = UserAvatarCropGeometry.selection(
            imageSize: portrait,
            viewportSide: 300,
            zoom: 1,
            offset: .zero
        )
        expectApproximately(centeredPortrait.x, 0, "竖图默认裁剪应覆盖完整宽度")
        expectApproximately(centeredPortrait.y, 0.25, "竖图默认裁剪应居中")
        expectApproximately(centeredPortrait.width, 1, "竖图默认裁剪宽度为 100%")
        expectApproximately(centeredPortrait.height, 0.5, "竖图默认裁剪为中央正方形")

        let zoomed = UserAvatarCropGeometry.selection(
            imageSize: landscape,
            viewportSide: 300,
            zoom: 2,
            offset: .zero
        )
        expectApproximately(zoomed.x, 0.375, "放大后仍以中心为锚点")
        expectApproximately(zoomed.y, 0.25, "放大后垂直裁剪居中")
        expectApproximately(zoomed.width, 0.25, "二倍缩放后可见宽度减半")
        expectApproximately(zoomed.height, 0.5, "二倍缩放后可见高度减半")

        let clamped = UserAvatarCropGeometry.clampedOffset(
            CGSize(width: 9_999, height: -9_999),
            imageSize: landscape,
            viewportSide: 300,
            zoom: 1
        )
        expectApproximately(clamped.width, 150, "拖动不能露出横向空白")
        expectApproximately(clamped.height, 0, "图片恰好覆盖高度时不可纵向拖动")

        expectApproximately(UserAvatarCropGeometry.clampedZoom(0.2), 1, "缩放下限为 1 倍")
        expectApproximately(UserAvatarCropGeometry.clampedZoom(20), 6, "缩放上限为 6 倍")

        print("✅ UserAvatarCropGeometryStandaloneTests 全部通过")
    }

    private static func expectApproximately(
        _ actual: CGFloat,
        _ expected: CGFloat,
        _ message: String,
        tolerance: CGFloat = 0.0001
    ) {
        guard abs(actual - expected) <= tolerance else {
            fatalError("断言失败：\(message)，实际 \(actual)，预期 \(expected)")
        }
        print("  ✓ \(message)")
    }
}
