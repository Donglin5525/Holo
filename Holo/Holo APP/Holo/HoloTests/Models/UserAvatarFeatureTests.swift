//
//  UserAvatarFeatureTests.swift
//  HoloTests
//
//  用户头像数据契约与输出图片测试。
//

import CoreData
import ImageIO
import UIKit
import XCTest
@testable import Holo

@MainActor
final class UserAvatarFeatureTests: XCTestCase {

    func testDataModelContainsCloudKitCompatibleAvatarEntity() throws {
        let entity = try XCTUnwrap(CoreDataTestSupport.sharedModel.entitiesByName["UserAvatarEntity"])
        let attributes = entity.attributesByName

        XCTAssertEqual(attributes["profileKey"]?.defaultValue as? String, "primary")
        XCTAssertEqual(attributes["state"]?.defaultValue as? String, "unset")
        XCTAssertEqual(attributes["revision"]?.defaultValue as? Int, 0)
        XCTAssertFalse(attributes["profileKey"]?.isOptional ?? true)
        XCTAssertFalse(attributes["state"]?.isOptional ?? true)
        XCTAssertTrue(attributes["avatarData"]?.isOptional ?? false)
        XCTAssertTrue(attributes["avatarData"]?.allowsExternalBinaryDataStorage ?? false)
    }

    func testRenderedAvatarIsSquareBoundedAndStripsGPSMetadata() async throws {
        let source = makeTestImage(size: CGSize(width: 1_600, height: 900))
        let rawData = try XCTUnwrap(source.jpegData(compressionQuality: 0.98))
        let prepared = try await UserAvatarImageProcessor.prepareForCropping(rawData)
        let preparedImage = try XCTUnwrap(UIImage(data: prepared))
        let selection = UserAvatarCropGeometry.selection(
            imageSize: preparedImage.size,
            viewportSide: 320,
            zoom: 1.4,
            offset: CGSize(width: 42, height: 0)
        )

        let output = try await UserAvatarImageProcessor.renderAvatar(
            preparedData: prepared,
            selection: selection
        )
        let outputImage = try XCTUnwrap(UIImage(data: output))

        XCTAssertLessThanOrEqual(output.count, UserAvatarImageProcessor.maximumOutputBytes)
        XCTAssertEqual(outputImage.cgImage?.width, UserAvatarImageProcessor.outputPixelSize)
        XCTAssertEqual(outputImage.cgImage?.height, UserAvatarImageProcessor.outputPixelSize)

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    private func makeTestImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            UIColor.systemYellow.setFill()
            context.cgContext.fill(
                CGRect(x: size.width * 0.55, y: 0, width: size.width * 0.45, height: size.height)
            )
        }
    }
}
