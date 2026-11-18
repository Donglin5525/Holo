//
//  StickerRenderer.swift
//  Holo
//
//  贴纸渲染层：从 VisualAsset 的像素字段产出「角色 × 外观」的显示图，并按完整 key
//  缓存派生结果（2026-11-16 方案 02 §7 / 04 §5.3；2026-11-18 全链路修复重构）。
//  - role 边宽：以「角色参考点尺寸」为基准按派生图长边等比缩放——icon 1.25pt / calendar
//    0.75pt / list 2.5pt / hero 4pt（标准档）在任何派生分辨率下视觉粗细一致
//  - 派生图先降采样到角色目标长边再合成纸边：icon 封顶 320px、hero 封顶 1024px，
//    单张 icon 内存从 ~9.4MB 降到 ~0.4MB，32MB 缓存稳存数十张（B2③根治）
//  - 主题只重绘纸边：浅色 #FAF8F2、深色 #D6D1C9（token colorset）；显式纯白跨模式保留
//  - 深色默认关闭投影；导出永远用固定浅色配置（预览可异、导出可预测）
//  - 缓存 key 是纯值签名（assetID+rendererVersion+role+pixelSize+外观+presentation 摘要），
//    不查 Core Data、不截断 base64——素材像素不可变，内容演进靠 rendererVersion 失效
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

    /// 角色参考显示尺寸（pt）：纸边粗细的等比基准
    var referencePointSize: CGFloat {
        switch self {
        case .icon: return 44
        case .calendar: return 32
        case .list: return 160
        case .hero: return 280
        case .custom: return 160
        }
    }

    /// 派生图目标长边（物理像素）：小角色封顶小档、大角色乘显示倍率后封顶 1024——
    /// 3x 设备上不再派生 2880px 巨图打爆缓存（B2③）
    func targetPixelSize(displayScale: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        switch self {
        case .icon: return min(160 * scale, 320)
        case .calendar: return min(96 * scale, 192)
        case .list: return min(480 * scale, 1024)
        case .hero: return min(960 * scale, 1024)
        case .custom: return min(480 * scale, 1024)
        }
    }
}

// MARK: - 渲染输入快照（线程安全值传递，不在后台线程触碰 viewContext 托管对象）

struct VisualAssetRenderSnapshot: Sendable {
    let kind: VisualAssetKind
    let sourceData: Data?
    let contentData: Data?
    let maskData: Data?
    let sourceWidth: Int
    let sourceHeight: Int

    init?(asset: VisualAsset) {
        guard let kind = VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) else { return nil }
        self.kind = kind
        self.sourceData = asset.value(forKey: "sourceData") as? Data
        self.contentData = asset.value(forKey: "contentData") as? Data
        self.maskData = asset.value(forKey: "maskData") as? Data
        self.sourceWidth = asset.value(forKey: "sourceWidth") as? Int ?? 0
        self.sourceHeight = asset.value(forKey: "sourceHeight") as? Int ?? 0
    }

    init(kind: VisualAssetKind, sourceData: Data?, contentData: Data?, maskData: Data?,
         sourceWidth: Int, sourceHeight: Int) {
        self.kind = kind
        self.sourceData = sourceData
        self.contentData = contentData
        self.maskData = maskData
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }
}

// MARK: - 渲染器

enum StickerRenderer {

    /// 缓存与渲染管线的版本号：像素管线变更时 +1 使全量派生缓存失效
    static let rendererVersion = 2

    /// 从素材像素产出显示图（含纸边/投影）。photo 走完整显示或按 presentation 取景，
    /// 不加纸边（04 §5.1：带背景照片是完整画面，不套白边）。
    static func renderDisplayImage(asset: VisualAsset,
                                   role: VisualRenderRole,
                                   appearance: ColorScheme,
                                   increasedContrast: Bool,
                                   displayScale: CGFloat,
                                   presentation: VisualPlacementPayload.Presentation?) -> CGImage? {
        guard let snapshot = VisualAssetRenderSnapshot(asset: asset) else { return nil }
        return renderDisplayImage(snapshot: snapshot, role: role, appearance: appearance,
                                  increasedContrast: increasedContrast, displayScale: displayScale,
                                  presentation: presentation)
    }

    static func renderDisplayImage(snapshot: VisualAssetRenderSnapshot,
                                   role: VisualRenderRole,
                                   appearance: ColorScheme,
                                   increasedContrast: Bool,
                                   displayScale: CGFloat,
                                   presentation: VisualPlacementPayload.Presentation?) -> CGImage? {
        switch snapshot.kind {
        case .photo:
            return renderPhoto(snapshot: snapshot, role: role, displayScale: displayScale, presentation: presentation)
        case .sticker:
            return renderSticker(snapshot: snapshot, role: role, appearance: appearance,
                                 increasedContrast: increasedContrast, displayScale: displayScale,
                                 presentation: presentation)
        }
    }

    /// 导出透明 PNG：固定浅色导出配置（用户显式选纯白/无边则遵从）
    static func renderExportImage(asset: VisualAsset,
                                  borderStyle: VisualPlacementPayload.Presentation.BorderStyle,
                                  displayScale: CGFloat) -> CGImage? {
        guard let snapshot = VisualAssetRenderSnapshot(asset: asset) else { return nil }
        return renderSticker(snapshot: snapshot, role: .hero, appearance: .light,
                             increasedContrast: false, displayScale: displayScale,
                             presentation: .init(borderStyle: borderStyle))
    }

    /// 确认页预览（不查库、不走缓存）：工作图 + 遮罩 + 当前纸边选择，先降采样到
    /// maxLongest 再合成——后台毫秒级完成，拖滑块/切纸边不重算全图（B5/B6 根治）
    static func renderConfirmPreview(subject: CGImage,
                                     mask: CVPixelBuffer,
                                     presentation: VisualPlacementPayload.Presentation,
                                     maxLongest: CGFloat = 960) -> CGImage? {
        var subj = subject
        var m = mask
        let longest = CGFloat(max(subject.width, subject.height))
        if longest > maxLongest {
            subj = VisualAssetImageProcessor.downscale(subject, targetLongest: maxLongest)
            guard let scaled = VisualAssetImageProcessor.downscaleMask(mask, width: subj.width, height: subj.height) else {
                return nil
            }
            m = scaled
        }
        let edgePoints: CGFloat
        switch presentation.borderWeight {
        case .thin: edgePoints = 2.5
        case .standard: edgePoints = 4
        }
        let edgeColor = paperEdgeColor(style: presentation.borderStyle, appearance: .light)
        // 确认页预览画布高 264pt：纸边按派生长边对参考尺寸等比，屏幕上读感≈设计 pt 值
        let previewRefPt: CGFloat = 264
        let radius = edgePoints * CGFloat(max(subj.width, subj.height)) / previewRefPt
        return VisualAssetImageProcessor.composeSticker(
            subject: subj, occupancyMask: m,
            edge: .init(radiusPixels: radius, color: edgeColor))
    }

    // MARK: - 私有

    private static func renderSticker(snapshot: VisualAssetRenderSnapshot,
                                      role: VisualRenderRole,
                                      appearance: ColorScheme,
                                      increasedContrast: Bool,
                                      displayScale: CGFloat,
                                      presentation: VisualPlacementPayload.Presentation?) -> CGImage? {
        guard let maskData = snapshot.maskData,
              let mask = VisualAssetImageProcessor.decodeMask(from: maskData,
                                                              width: snapshot.sourceWidth,
                                                              height: snapshot.sourceHeight) else {
            // 素材像素不完整：显示占位由调用方处理，这里不伪造
            return nil
        }
        let maskW = CVPixelBufferGetWidth(mask)
        let maskH = CVPixelBufferGetHeight(mask)
        let decodedContent = snapshot.contentData
            .flatMap { VisualAssetImageProcessor.decodeWorkingCGImage(from: $0) }
        let decodedSource = snapshot.sourceData
            .flatMap { VisualAssetImageProcessor.decodeWorkingCGImage(from: $0) }
        // 若 content 与 mask 尺寸一致（正常紧裁或同尺寸），直接用 content；
        // 兼容历史未同步裁剪 mask 的旧素材：回退到与 mask 同尺寸的 sourceData
        let content: CGImage?
        if let c = decodedContent, c.width == maskW, c.height == maskH {
            content = c
        } else if let s = decodedSource, s.width == maskW, s.height == maskH {
            content = s
        } else {
            content = decodedContent ?? decodedSource
        }
        guard let content else { return nil }
        let p = presentation ?? VisualPlacementPayload.Presentation()
        let edgePoints: CGFloat
        switch p.borderWeight {
        case .thin: edgePoints = role.thinEdgePoints
        case .standard: edgePoints = role.standardEdgePoints
        }
        let edgeColor = paperEdgeColor(style: p.borderStyle, appearance: appearance)
        // 先降采样再合成（B2③）：画面与遮罩同步缩到角色目标长边
        let target = role.targetPixelSize(displayScale: displayScale)
        var subject = content
        var occupancyMask = mask
        if CGFloat(max(content.width, content.height)) > target {
            subject = VisualAssetImageProcessor.downscale(content, targetLongest: target)
            occupancyMask = VisualAssetImageProcessor.downscaleMask(mask, width: subject.width, height: subject.height) ?? mask
        }
        // 纸边像素 = 设计 pt × 派生长边 / 角色参考 pt：任何派生分辨率下视觉粗细一致
        let radius = edgePoints * CGFloat(max(subject.width, subject.height)) / role.referencePointSize
        // 角色禁旋转/禁投影属 role 适配，不写回负载（02 §4.4）
        let spec = VisualAssetImageProcessor.PaperEdgeSpec(radiusPixels: radius, color: edgeColor)
        return VisualAssetImageProcessor.composeSticker(subject: subject, occupancyMask: occupancyMask, edge: spec)
    }

    private static func paperEdgeColor(style: VisualPlacementPayload.Presentation.BorderStyle,
                                       appearance: ColorScheme) -> CGColor {
        switch style {
        case .adaptivePaper:
            return UIColor(named: "VisualStickerPaper")?.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: appearance == .dark ? .dark : .light)).cgColor
                ?? CGColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        case .white:
            return UIColor(named: "VisualStickerPaperExplicitWhite")?.cgColor
                ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .none:
            return CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    private static func renderPhoto(snapshot: VisualAssetRenderSnapshot,
                                    role: VisualRenderRole,
                                    displayScale: CGFloat,
                                    presentation: VisualPlacementPayload.Presentation?) -> CGImage? {
        guard let sourceData = snapshot.sourceData,
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

    /// 纯值签名 key（B2④根治）：不查 Core Data、不含随机 UUID、不截断 base64——
    /// presentation 用确定性摘要，不同样式/缩放/主题互不撞 key
    static func key(assetID: UUID, role: VisualRenderRole, appearance: ColorScheme,
                    increasedContrast: Bool, displayScale: CGFloat,
                    presentation: VisualPlacementPayload.Presentation?) -> String {
        let pKey = presentation.map(presentationKey) ?? "default"
        let pixel = Int(role.targetPixelSize(displayScale: displayScale))
        let roleKey: String
        switch role {
        case .icon: roleKey = "icon"
        case .calendar: roleKey = "calendar"
        case .list: roleKey = "list"
        case .hero: roleKey = "hero"
        case .custom(let e): roleKey = "custom\(Int(e * 10))"
        }
        return "\(assetID.uuidString)|r\(StickerRenderer.rendererVersion)|\(roleKey)|p\(pixel)"
            + "|\(appearance == .dark ? "d" : "l")|c\(increasedContrast ? 1 : 0)|\(pKey)"
    }

    /// presentation 确定性摘要：量化到百分位/十分位，微小浮点差不产生新 key
    static func presentationKey(_ p: VisualPlacementPayload.Presentation) -> String {
        "f\(p.fit.rawValue)"
            + "-x\(Int((p.focusX * 100).rounded()))"
            + "-y\(Int((p.focusY * 100).rounded()))"
            + "-s\(Int((p.scale * 100).rounded()))"
            + "-r\(Int((p.rotationDegrees * 10).rounded()))"
            + "-b\(p.borderStyle.rawValue)"
            + "-w\(p.borderWeight.rawValue)"
            + "-sft\(p.softenPhotoInDark ? 1 : 0)"
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

    /// 按素材精准失效（素材删除/重做时清它的全部派生档）
    static func removeImages(assetID: UUID) {
        let prefix = assetID.uuidString + "|"
        lock.lock(); defer { lock.unlock() }
        for key in store.keys where key.hasPrefix(prefix) {
            store[key] = nil
        }
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
