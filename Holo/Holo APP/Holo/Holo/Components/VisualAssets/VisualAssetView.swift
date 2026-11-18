//
//  VisualAssetView.swift
//  Holo
//
//  共用视觉渲染组件（方案 02 §7；2026-11-18 全链路修复重构）：
//  descriptor + role 进、显示图出；渲染层不查业务模块。
//  - 首帧同步命中缓存：body 直接读 VisualRenderCache，缓存有图绝不闪灰块（B2②）
//  - body 零 Core Data 查询：fetch 移入 .task，用纯值 fastKey 驱动（B2⑤）
//  - 后台渲染只传 Sendable 值快照，不跨线程触碰 NSManagedObject；
//    深浅/对比度/尺寸变化自动重渲染；迟到结果只在 key 匹配时落地
//

import SwiftUI
import CoreData

struct VisualAssetView: View {
    let descriptor: VisualDescriptor
    var role: VisualRenderRole = .icon
    @Environment(\.colorScheme) private var colorScheme

    @State private var displayImage: CGImage?

    var body: some View {
        GeometryReader { geo in
            // 首帧同步命中：缓存有图直接出图，重建视图不再先闪灰块（B2②）
            let image = displayImage ?? VisualRenderCache.image(for: fastKey)
            Group {
                if let image {
                    let p = descriptor.presentation
                    let scale = min(max(p?.scale ?? 1.0, 0.6), 1.2)
                    let ox = min(max(p?.offsetX ?? 0, -0.5), 0.5)
                    let oy = min(max(p?.offsetY ?? 0, -0.5), 0.5)
                    Image(uiImage: UIImage(cgImage: image))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(x: ox * geo.size.width, y: oy * geo.size.height)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    // 像素未就绪：中性占位（区分「还没到」与「坏了」由外层状态负责）
                    RoundedRectangle(cornerRadius: roleCornerRadius)
                        .fill(Color.holoToolInset)
                }
            }
        }
        .task(id: fastKey) {
            await render()
        }
    }

    private var roleCornerRadius: CGFloat {
        switch role {
        case .icon, .calendar: return 10
        default: return 16
        }
    }

    /// 纯值签名渲染 key：不查库（B2⑤），素材/样式/主题/倍率任一变化自动重渲
    private var fastKey: String {
        VisualRenderCache.key(assetID: descriptor.assetID, role: role, appearance: colorScheme,
                              increasedContrast: UIAccessibility.isDarkerSystemColorsEnabled,
                              displayScale: displayScale, presentation: descriptor.presentation)
    }

    private var displayScale: CGFloat { UIScreen.main.scale }
    private var displaySize: CGSize { .init(width: 200, height: 200) }

    /// 渲染路径绝不向 context 插对象（曾因 fetch miss 兜底 insert 残缺对象，
    /// 导致 viewContext 带脏 + CloudKit 同步 id=nil 半成品——闪退+污染库，已根治）
    private var proxyAsset: VisualAsset? {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "id == %@", descriptor.assetID as CVarArg)
        request.fetchLimit = 1
        return try? CoreDataStack.shared.viewContext.fetch(request).first
    }

    private func render() async {
        let key = fastKey
        if let cached = VisualRenderCache.image(for: key) {
            displayImage = cached
            return
        }
        // fetch 只在 task 里做，body 永不查库（B2⑤）
        guard let snapshot = await MainActor.run(body: {
            proxyAsset.flatMap { VisualAssetRenderSnapshot(asset: $0) }
        }) else { return }
        let scale = await MainActor.run { displayScale }
        let scheme = await MainActor.run { colorScheme }
        let contrast = await MainActor.run { UIAccessibility.isDarkerSystemColorsEnabled }
        let presentation = descriptor.presentation
        // 后台渲染（02 §7：不阻塞主线程；仅传 Sendable 值快照，不跨线程触碰 NSManagedObject）
        let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            StickerRenderer.renderDisplayImage(snapshot: snapshot, role: role, appearance: scheme,
                                               increasedContrast: contrast, displayScale: scale,
                                               presentation: presentation)
        }.value
        guard let rendered else { return }
        VisualRenderCache.storeImage(rendered, for: key)
        // 迟到结果只在 key 仍匹配时落地（快速切换防旧图闪现）
        await MainActor.run {
            if fastKey == key { displayImage = rendered }
        }
    }
}

/// 解析状态 → 视图的统一入口（各模块共用同一判断，不各自兜底）
struct VisualPlacementView: View {
    let placement: ResolvedPlacement
    var role: VisualRenderRole = .icon

    var body: some View {
        switch placement {
        case .assetReady(let descriptor):
            VisualAssetView(descriptor: descriptor, role: role)
        case .pending:
            placeholder(label: "同步中")
        case .deleted:
            placeholder(label: "已删除")
        case .unsupported:
            placeholder(label: "新版本内容")
        case .corrupt:
            placeholder(label: "内容异常")
        case .none, .recordSelected:
            EmptyView()
        }
    }

    private func placeholder(label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.holoToolInset)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.holoToolTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(3)
        }
    }
}
