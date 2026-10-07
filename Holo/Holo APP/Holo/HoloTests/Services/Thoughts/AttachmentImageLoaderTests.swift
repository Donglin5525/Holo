//
//  AttachmentImageLoaderTests.swift
//  HoloTests
//
//  附件图片统一加载通道单测：真解码（像素就绪+降采样）、共享缓存命中（同实例）、
//  内容哈希键跨调用复用。
//

import XCTest
import UIKit
@testable import Holo

final class AttachmentImageLoaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AttachmentImageLoader.removeAll()
    }

    /// 生成纯色 JPEG 测试数据
    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "test", code: 1)
        }
        return data
    }

    @MainActor
    func test_解码返回降采样后的就绪位图() async throws {
        // 1200×900 输入、缩略图上限 600 → 长边压到 600（300 物理缩略图不会被放大）
        let data = try makeJPEG(width: 1200, height: 900)
        let image = await AttachmentImageLoader.decodedThumbnail(from: data)
        let decoded = try XCTUnwrap(image)
        let cg = try XCTUnwrap(decoded.cgImage)
        XCTAssertEqual(cg.width, 600)
        XCTAssertEqual(cg.height, 450)
    }

    @MainActor
    func test_同数据二次调用命中缓存_同实例返回() async throws {
        let data = try makeJPEG(width: 300, height: 300)
        let first = await AttachmentImageLoader.decodedThumbnail(from: data)
        let second = await AttachmentImageLoader.decodedThumbnail(from: data)
        XCTAssertTrue(first === second, "缓存命中应返回同一实例，不再重复解码")
    }

    @MainActor
    func test_同步缓存查询_在异步解码后可用() async throws {
        let data = try makeJPEG(width: 300, height: 300)
        XCTAssertNil(AttachmentImageLoader.cachedThumbnail(for: data), "未解码前同步查询应为空")
        _ = await AttachmentImageLoader.decodedThumbnail(from: data)
        XCTAssertNotNil(AttachmentImageLoader.cachedThumbnail(for: data), "异步解码后 body 同步查询应命中")
    }

    @MainActor
    func test_清空缓存后重新解码() async throws {
        let data = try makeJPEG(width: 300, height: 300)
        let first = await AttachmentImageLoader.decodedThumbnail(from: data)
        AttachmentImageLoader.removeAll()
        let second = await AttachmentImageLoader.decodedThumbnail(from: data)
        XCTAssertFalse(first === second, "清空后应重新解码，返回新实例")
    }

    @MainActor
    func test_不同数据互不串图() async throws {
        let dataA = try makeJPEG(width: 300, height: 300)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300))
        let imageB = renderer.image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let dataB = try XCTUnwrap(imageB.jpegData(compressionQuality: 0.8))
        let a = await AttachmentImageLoader.decodedThumbnail(from: dataA)
        let b = await AttachmentImageLoader.decodedThumbnail(from: dataB)
        XCTAssertFalse(a === b, "内容哈希键下不同图不得命中同一条缓存")
    }
}
