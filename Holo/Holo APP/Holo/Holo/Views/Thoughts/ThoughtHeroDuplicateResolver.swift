//
//  ThoughtHeroDuplicateResolver.swift
//  Holo
//
//  列表里「头图与正文附件是同一张照片」的判定（方案 01 §6.3-6：头图不与附件重复显示）。
//  头图选择器目前没有「从附件设头图」入口，同一张图会被加两次；两次落库的编码与尺寸
//  都不同（附件存原图 + 正方形缩略图，头图存重编码的工作图），文件哈希对不上，只能比画面：
//  各取中心方裁压到 24×24 灰度，相关系数达到 0.997 才算同一张。门槛用真实照片校准过——
//  同一张照片换编码重存 ≈ 0.9999，画面平移 1% 就掉到 0.992。标准卡得严是有意的：
//  判错「不同」只是多显示一张缩略图，判错「相同」会把用户的一张照片藏起来。
//

import CoreData
import CoreGraphics
import ImageIO

enum ThoughtHeroPhotoFingerprint {
    static let side = 24
    /// 比对前的取样精度：太粗（≤32px）时同一张照片重编码后也只有 0.995，与「略有差别的另一张」分不开
    static let sampleMaxPixelSize = 256
    static let samePhotoCorrelation: Double = 0.997
    /// 画面几乎没有明暗差（纯色天空、白墙）时不参与判定：这类图之间天然「长得一样」
    static let minimumContrast: Double = 6

    struct Fingerprint: Sendable {
        let pixels: [UInt8]
        let mean: Double
        let standardDeviation: Double
    }

    static func fingerprint(from data: Data) -> Fingerprint? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleMaxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        // 中心方裁：附件缩略图本来就是原图的中心正方形，头图缩略图是全画面，取同样的中心方裁才可比
        let short = min(thumbnail.width, thumbnail.height)
        guard short > 0,
              let square = thumbnail.cropping(to: CGRect(x: (thumbnail.width - short) / 2,
                                                         y: (thumbnail.height - short) / 2,
                                                         width: short, height: short)) else {
            return nil
        }
        let count = side * side
        // 显式分配再拷出：CGBitmapContext 会保留缓冲区指针，不能交出 Swift 数组的瞬时地址
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<UInt8>.alignment)
        defer { buffer.deallocate() }
        guard let context = CGContext(data: buffer, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: count))
        let mean = Double(pixels.reduce(0) { $0 + Int($1) }) / Double(count)
        let variance = Double(pixels.reduce(0) { $0 + (Double($1) - mean) * (Double($1) - mean) }) / Double(count)
        return Fingerprint(pixels: pixels, mean: mean, standardDeviation: variance.squareRoot())
    }

    static func isSamePhoto(_ a: Fingerprint, _ b: Fingerprint) -> Bool {
        guard a.pixels.count == b.pixels.count, !a.pixels.isEmpty,
              a.standardDeviation >= minimumContrast, b.standardDeviation >= minimumContrast else {
            return false
        }
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for (x, y) in zip(a.pixels, b.pixels) {
            let dx = Double(x) - a.mean, dy = Double(y) - b.mean
            covariance += dx * dy
            varianceA += dx * dx
            varianceB += dy * dy
        }
        return covariance / (varianceA.squareRoot() * varianceB.squareRoot()) >= samePhotoCorrelation
    }
}

/// 想法卡用的判定入口：主线程取数与查缓存，像素比对放后台
@MainActor
enum ThoughtHeroDuplicateResolver {

    private struct Candidate: Sendable {
        let id: UUID
        let thumbnailData: Data?
        let thumbnailURL: URL?
        let cacheKey: String
    }

    private static var verdicts: [String: Bool] = [:]
    private static let verdictCapacity = 512

    /// 重算身份：头图素材或附件集合变了才重算；没有照片头图或没有附件时为 nil
    static func key(hero: ResolvedPlacement, attachments: [ThoughtAttachment]) -> String? {
        guard case .assetReady(let descriptor) = hero, descriptor.kind == .photo else { return nil }
        return descriptor.assetID.uuidString + "|" + attachments.map { $0.id.uuidString }.joined(separator: ",")
    }

    static func duplicateIDs(hero: ResolvedPlacement, attachments: [ThoughtAttachment],
                             in context: NSManagedObjectContext) async -> Set<UUID> {
        guard case .assetReady(let descriptor) = hero, descriptor.kind == .photo else { return [] }
        // 「从附件设头图」会记下来源附件：命中即同一张，不必比画面
        if let source = descriptor.sourceAttachmentID, attachments.contains(where: { $0.id == source }) {
            return [source]
        }
        guard !attachments.isEmpty,
              let asset = VisualAssetRepository.shared.findAsset(byID: descriptor.assetID, in: context),
              let heroData = asset.value(forKey: "thumbnailData") as? Data else {
            return []
        }

        var duplicates = Set<UUID>()
        var pending: [Candidate] = []
        for attachment in attachments {
            let inline = attachment.thumbnailData
            let cacheKey = descriptor.assetID.uuidString + "|" + attachment.id.uuidString
                + "|" + String(inline?.count ?? -1) + "|" + attachment.thumbnailFileName
            if let cached = verdicts[cacheKey] {
                if cached { duplicates.insert(attachment.id) }
                continue
            }
            // 缩略图不在库里时是磁盘文件（Documents/Attachments/{想法id}/），路径在主线程算好，
            // 文件内容留给后台读
            var thumbnailURL: URL?
            if inline == nil, let thoughtID = attachment.thought?.id {
                thumbnailURL = AttachmentFileManager.taskDirectory(taskId: thoughtID)
                    .appendingPathComponent(attachment.thumbnailFileName)
            }
            pending.append(Candidate(id: attachment.id, thumbnailData: inline,
                                     thumbnailURL: thumbnailURL, cacheKey: cacheKey))
        }
        guard !pending.isEmpty else { return duplicates }

        let resolved = await Task.detached(priority: .utility) { () -> [(id: UUID, cacheKey: String, isDuplicate: Bool)] in
            guard let heroPrint = ThoughtHeroPhotoFingerprint.fingerprint(from: heroData) else { return [] }
            return pending.compactMap { candidate in
                let data = candidate.thumbnailData ?? candidate.thumbnailURL.flatMap { try? Data(contentsOf: $0) }
                guard let data, let print = ThoughtHeroPhotoFingerprint.fingerprint(from: data) else { return nil }
                return (candidate.id, candidate.cacheKey,
                        ThoughtHeroPhotoFingerprint.isSamePhoto(heroPrint, print))
            }
        }.value

        for entry in resolved {
            if entry.isDuplicate { duplicates.insert(entry.id) }
            verdicts[entry.cacheKey] = entry.isDuplicate
        }
        if verdicts.count > verdictCapacity { verdicts.removeAll() }
        return duplicates
    }
}
