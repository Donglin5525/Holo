//
//  StickerRenderer.swift
//  Holo
//
//  贴纸渲染层：从 VisualAsset 的像素字段产出「角色 × 外观」的显示图，并按完整 key
//  缓存派生结果（2026-11-16 方案 02 §7 / 04 §5.3）。
//  - role 边宽（pt × displayScale → px）：icon 1.25 / calendar 0.75 / list 2.5 / hero 4（标准档）
//  - 主题只重绘纸边：浅色 #FAF8F2、深色 #D6D1C9（token colorset）；显式纯白跨模式保留
//  - 深色默认关闭投影；导出永远用固定浅色配置（预览可异、导出可预测）
//  - 缓存 key 含 assetID+contentHash+maskHash+revisionID+rendererVersion+role+pixelSize
//    +displayScale+appearance+contrast+presentationHash；主题切换不得命中旧缓存
//

import SwiftUI
import CoreData
import CoreGraphics

// MARK: - 角色（04 §5.3 role 参数表）

enum VisualRenderRole {
    case icon        // 44pt 列表图标位
    case calendar    // 32pt 月历格
    case list        // 160pt 列表头图
    case hero        // 280pt 详情头图
    case custom(edgePoints: CGFloat)

    /// 标准档纸边（pt）；其他尺寸按角色参考边长等比缩放并限制在 0.75–1.5 倍
    var standardEdgePoints: CGFloat {
        switch self {
        case .icon: return 1.25
        case .calendar: return 0.75
        case .list: return 2.5
        case .hero: return 4
        case .custom(let edgePoints): return min(max(edgePoints, 0.75), 6)
        }
    }
    /// 细档 = 标准 × 0.6
    var thinEdgePoints: CGFloat { standardEdgePoints * 0.6 }

    /// 派生图目标长边像素
    func targetPixelSize(displayScale: CGFloat) -> CGFloat {
        let base: CGFloat
        switch self {
        case .icon, .calendar: base = 320      // 小角色用 320px 源缩略图派生
        case .list: base = 600
        case .hero: base = 960
        case .custom: base = 600
        }
        return base * displayScale
    }
}

// MARK: - 渲染器

enum StickerRenderer {

    static let rendererVersion = 1

    /// 从素材像素产出显示图（含纸边/投影）。photo 走完整显示或按 presentation 取景，
    /// 不加纸边（04 §5.1：带背景照片是完整画面，不套白边）。
    static func renderDisplayImage(asset: VisualAsset,
                                   role: VisualRenderRole,
                                   appearance: ColorScheme,
                                   increasedContrast: Bool,
                                   displayScale: CGFloat,
                                   presentation: VisualPlacementPayload.Presentation?) -> CGImage? {
        guard let kind = VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) else { return nil }
        switch kind {
        case .photo:
            return renderPhoto(asset: asset, role: role, displayScale: displayScale, presentation: presentation)
        case .sticker:
            return renderSticker(asset: asset, role: role, appearance: appearance,
                                 increasedContrast: increasedContrast, displayScale: displayScale,
                                 presentation: presentation)
        }
    }

    /// 导出透明 PNG：固定浅色导出配置（用户显式选纯白/无边则遵从）
    static func renderExportImage(asset: VisualAsset,
                                  borderStyle: VisualPlacementPayload.Presentation.BorderStyle,
                                  displayScale: CGFloat) -> CGImage? {
        renderSticker(asset: asset, role: .hero, appearance: .light,
                      increasedContrast: false, displayScale: displayScale,
                      presentation: .init(borderStyle: borderStyle))
    }

    /// 确认页即时预览（不查库、不走缓存：工作图 + 遮罩 + 当前纸边选择直接合成）
    static func renderDisplayImageForPreview(subject: CGImage,
                                             mask: CVPixelBuffer,
                                             presentation: VisualPlacementPayload.Presentation) -> CGImage? {
        let edgePoints: CGFloat
        switch presentation.borderWeight {
        case .thin: edgePoints = 2.5
        case .standard: edgePoints = 4
        }
        let edgeColor: CGColor
        switch presentation.borderStyle {
        case .adaptivePaper:
            edgeColor = UIColor(named: "VisualStickerPaper")?.cgColor
                ?? CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        case .white:
            edgeColor = UIColor(named: "VisualStickerPaperExplicitWhite")?.cgColor
                ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .none:
            edgeColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        return VisualAssetImageProcessor.composeSticker(
            subject: subject, occupancyMask: mask,
            edge: .init(radiusPixels: edgePoints * UIScreen.main.scale, color: edgeColor))
    }

    // MARK: - 私有

    private static func renderSticker(asset: VisualAsset,
                                      role: VisualRenderRole,
                                      appearance: ColorScheme,
                                      increasedContrast: Bool,
                                      displayScale: CGFloat,
                                      presentation: VisualPlacementPayload.Presentation?) -> CGImage? {
        guard let contentData = asset.value(forKey: "contentData") as? Data
                ?? asset.value(forKey: "sourceData") as? Data,
              let content = VisualAssetImageProcessor.decodeWorkingCGImage(from: contentData),
              let maskData = asset.value(forKey: "maskData") as? Data,
              let mask = VisualAssetImageProcessor.decodeMask(from: maskData,
                                                              width: asset.value(forKey: "sourceWidth") as? Int ?? content.width,
                                                              height: asset.value(forKey: "sourceHeight") as? Int ?? content.height) else {
            // 素材像素不完整：显示占位由调用方处理，这里不伪造
            return nil
        }
        let p = presentation ?? VisualPlacementPayload.Presentation()
        let edgePoints: CGFloat
        switch p.borderWeight {
        case .thin: edgePoints = role.thinEdgePoints
        case .standard: edgePoints = role.standardEdgePoints
        }
        let edgeColor: CGColor
        switch p.borderStyle {
        case .adaptivePaper:
            edgeColor = UIColor(named: "VisualStickerPaper")?.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: appearance == .dark ? .dark : .light)).cgColor
                ?? CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        case .white:
            edgeColor = UIColor(named: "VisualStickerPaperExplicitWhite")?.cgColor
                ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .none:
            edgeColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        // 角色禁旋转/禁投影属 role 适配，不写回负载（02 §4.4）
        let spec = VisualAssetImageProcessor.PaperEdgeSpec(
            radiusPixels: edgePoints * displayScale,
            color: edgeColor)
        return VisualAssetImageProcessor.composeSticker(subject: content, occupancyMask: mask, edge: spec)
    }

    private static func renderPhoto(asset: VisualAsset,
                                    role: VisualRenderRole,
                                    displayScale: CGFloat,
                                    presentation: VisualPlacementPayload.Presentation?) -> CGImage? {
        guard let sourceData = asset.value(forKey: "sourceData") as? Data,
              let image = VisualAssetImageProcessor.decodeWorkingCGImage(from: sourceData) else { return nil }
        let p = presentation ?? VisualPlacementPayload.Presentation()
        let target = role.targetPixelSize(displayScale: displayScale)
        // 深色夜间柔光（仅预览；导出忽略——由 renderExportImage 的固定路径保证）
        if p.softenPhotoInDark {
            return VisualAssetImageProcessor.softenPhoto(image, targetLongest: target)
        }
        return VisualAssetImageProcessor.downscale(image, targetLongest: target)
    }
}

// MARK: - 派生缓存（可删除重建；素材库与 Core Data 是事实源，不当缓存清空）

enum VisualRenderCache {

    /// 进程内 LRU（初值 32MB 预算与附件缓存一起测总内存——02 §7）
    private final class Box { let image: CGImage; let bytes: Int; init(_ i: CGImage) { image = i; bytes = i.bytesPerRow * i.height } }
    private static let lock = NSLock()
    private static var store: [String: Box] = [:]
    private static var budget = 32 * 1024 * 1024

    static func key(asset: VisualAsset, role: VisualRenderRole, appearance: ColorScheme,
                    increasedContrast: Bool, displayScale: CGFloat,
                    presentation: VisualPlacementPayload.Presentation?) -> String {
        let assetID = (asset.value(forKey: "id") as? UUID)?.uuidString ?? "?"
        let contentHash = (asset.value(forKey: "contentHash") as? String) ?? "?"
        let maskHash = (asset.value(forKey: "maskHash") as? String) ?? "?"
        let renderer = StickerRenderer.rendererVersion
        let pixel = role.targetPixelSize(displayScale: displayScale)
        let contrast = increasedContrast ? 1 : 0
        let scheme = appearance == .dark ? "d" : "l"
        let presentationHash: String
        if let p = presentation,
           let data = try? VisualPlacementCoding.canonicalData(.setAsset(.asset(UUID()), presentation: p)) {
            presentationHash = String(data.base64EncodedString().prefix(24))
        } else {
            presentationHash = "default"
        }
        return "\(assetID)|\(contentHash)|\(maskHash)|r\(renderer)|p\(Int(pixel))|\(scheme)|c\(contrast)|\(presentationHash)"
    }

    static func image(for key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return store[key]?.image
    }

    static func storeImage(_ image: CGImage, for key: String) {
        lock.lock(); defer { lock.unlock() }
        let box = Box(image)
        store[key] = box
        evictIfNeeded(added: box.bytes)
    }

    /// 账号切换清内存缓存（scope 目录的可重建文件缓存后续挂 P5）
    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }

    private static func evictIfNeeded(added: Int) {
        var total = store.values.reduce(0) { $0 + $1.bytes } 
        if total <= budget { return }
        // 简单驱逐：按插入序（字典序 key 近似 LRU 替代；准确 LRU 待实测压力后再做）
        for key in store.keys.sorted() {
            guard total > budget else { break }
            total -= store[key]?.bytes ?? 0
            store[key] = nil
        }
    }
}
