//
//  AttachmentImageLoader.swift
//  Holo
//
//  附件图片统一加载通道：内存缓存 + 后台真解码 + 附件二进制后台读取。
//  此前全 App 没有任何图片缓存，且 UIImage(data:) 是惰性解码——标着「解码放后台」
//  的路径只把打包放进了后台，真正的像素解码仍落在主线程首帧渲染上。
//  这里统一走 CGImageSource 强制解码（像素就绪才返回），解码结果按内容哈希缓存，
//  「滚动回收再复用」「跨界面看同一张图」都不再重复解码；
//  附件大字段（原图/缩略图与原图同存一行）改经后台 context 按 objectID 读取，
//  主线程不再为看图付 SQLite IO。
//

import UIKit
import CryptoKit
import CoreData

nonisolated enum AttachmentImageLoader {

    /// NSCache 自身线程安全；成本按位图字节数计、总上限约 128MB，
    /// 系统内存吃紧时自动逐出，调用方无需手动清理。
    private nonisolated(unsafe) static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    /// 缩略图解码上限：卡片显示尺寸最大约 234pt × 3x ≈ 700px，
    /// 缩略图物理 300px 不会被放大，600 只是给未来更大缩略图留的帽子。
    private static let thumbnailMaxPixel: CGFloat = 600
    /// 全屏解码上限：iPhone 最大屏长边（2796pt 物理像素），原图 ≤2048 不会被放大。
    private static let fullScreenMaxPixel: CGFloat = 2796

    // MARK: - 内存数据解码（缩略图等已在手上的 Data）

    /// 同步缓存查询：命中返回像素就绪的位图，未命中返回 nil（不触发解码）。
    /// 供视图 body 直接调用——滚动回位时缓存命中可免掉「闪一帧占位图」。
    static func cachedThumbnail(for data: Data) -> UIImage? {
        cache.object(forKey: cacheKey(data, maxPixelSize: thumbnailMaxPixel))
    }

    /// 解码图片数据（先查缓存，未命中后台强制解码后入缓存）。
    static func decodedThumbnail(from data: Data) async -> UIImage? {
        let key = cacheKey(data, maxPixelSize: thumbnailMaxPixel)
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            AttachmentFileManager.fullyDecodedImage(from: data, maxPixelSize: thumbnailMaxPixel)
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: bitmapBytes(image))
        }
        return image
    }

    // MARK: - 附件二进制后台读取（原图 / 缩略图）

    /// 读取附件缩略图并解码：二进制经后台 context 按 objectID 取（不 fire 主线程
    /// 托管对象、不连带读出同行的原图大字段），命中缓存时连后台读取都省掉。
    static func thumbnail(objectID: NSManagedObjectID,
                          fallbackFileName: String? = nil,
                          ownerID: UUID? = nil) async -> UIImage? {
        let objectKey = objectCacheKey(objectID, kind: "thumb")
        if let hit = cache.object(forKey: objectKey) { return hit }
        let data = await attachmentBlob(objectID: objectID, key: "thumbnailData",
                                        fallbackFileName: fallbackFileName, ownerID: ownerID)
        guard let data else { return nil }
        let image = await decodedThumbnail(from: data)
        if let image {
            cache.setObject(image, forKey: objectKey, cost: bitmapBytes(image))
        }
        return image
    }

    /// 读取附件原图并解码为全屏位图：整个链路（blob 读取 + 解码）都在后台。
    static func fullImage(objectID: NSManagedObjectID,
                          fallbackFileName: String? = nil,
                          ownerID: UUID? = nil) async -> UIImage? {
        let objectKey = objectCacheKey(objectID, kind: "full")
        if let hit = cache.object(forKey: objectKey) { return hit }
        let data = await attachmentBlob(objectID: objectID, key: "imageData",
                                        fallbackFileName: fallbackFileName, ownerID: ownerID)
        guard let data else { return nil }
        let image = await Task.detached(priority: .userInitiated) {
            AttachmentFileManager.fullyDecodedImage(from: data, maxPixelSize: fullScreenMaxPixel)
        }.value
        if let image {
            cache.setObject(image, forKey: objectKey, cost: bitmapBytes(image))
        }
        return image
    }

    /// 清空缓存（诊断/内存自检入口；日常无需调用，NSCache 会随系统压力自行逐出）。
    static func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: - 私有

    /// 后台读取附件二进制：KVC 取字段名（ThoughtAttachment / TaskAttachment 同名），
    /// CoreData 旧附件只有磁盘文件，二进制读不到时回退文件系统。
    private static func attachmentBlob(objectID: NSManagedObjectID,
                                       key: String,
                                       fallbackFileName: String?,
                                       ownerID: UUID?) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let context = CoreDataStack.shared.persistentContainer.newBackgroundContext()
            let blob = try? await context.perform {
                (try? context.existingObject(with: objectID))?.value(forKey: key) as? Data
            }
            if let blob { return blob }
            guard let fallbackFileName, let ownerID else { return nil }
            let url = AttachmentFileManager.taskDirectory(taskId: ownerID)
                .appendingPathComponent(fallbackFileName)
            return try? Data(contentsOf: url)
        }.value
    }

    /// 内容哈希键：跨界面同图天然命中；SHA256 前 8 字节（64bit）碰撞概率工程上为零。
    private static func cacheKey(_ data: Data, maxPixelSize: CGFloat) -> NSString {
        let digest = SHA256.hash(data: data).prefix(8)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "data-\(Int(maxPixelSize))-\(hex)" as NSString
    }

    private static func objectCacheKey(_ objectID: NSManagedObjectID, kind: String) -> NSString {
        "obj-\(kind)-\(objectID.uriRepresentation().absoluteString)" as NSString
    }

    private static func bitmapBytes(_ image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }
}
