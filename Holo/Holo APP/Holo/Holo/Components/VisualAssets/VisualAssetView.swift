//
//  VisualAssetView.swift
//  Holo
//
//  共用视觉渲染组件（方案 02 §7）：descriptor + role 进、显示图出；
//  渲染层不查业务模块。后台渲染 + 全维缓存 key；深浅/对比度变化自动重渲染。
//  pending/deleted/unsupported 由调用方给出占位与文案，本组件只管「有图可显」的路径。
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
            Group {
                if let displayImage {
                    Image(uiImage: UIImage(cgImage: displayImage))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    // 像素未就绪：中性占位（区分「还没到」与「坏了」由外层状态负责）
                    RoundedRectangle(cornerRadius: roleCornerRadius)
                        .fill(Color.holoToolInset)
                }
            }
        }
        .task(id: renderKey) {
            await render(size: displaySize)
        }
    }

    private var roleCornerRadius: CGFloat {
        switch role {
        case .icon, .calendar: return 10
        default: return 16
        }
    }

    private var renderKey: String {
        // 增强对比走 UIKit 全局开关（isDarkerSystemColorsEnabled），进缓存 key
        VisualRenderCache.key(asset: proxyAsset, role: role, appearance: colorScheme,
                              increasedContrast: UIAccessibility.isDarkerSystemColorsEnabled,
                              displayScale: displayScale, presentation: descriptor.presentation)
    }

    private var displayScale: CGFloat { UIScreen.main.scale }
    private var displaySize: CGSize { .init(width: 200, height: 200) }

    private var proxyAsset: VisualAsset {
        // 缓存 key 只读字段；通过临时 fetch 拿托管对象（主线程 context）
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "id == %@", descriptor.assetID as CVarArg)
        request.fetchLimit = 1
        return (try? CoreDataStack.shared.viewContext.fetch(request).first) ?? VisualAsset(context: CoreDataStack.shared.viewContext)
    }

    private func render(size: CGSize) async {
        let key = renderKey
        if let cached = VisualRenderCache.image(for: key) {
            await MainActor.run { displayImage = cached }
            return
        }
        let asset = await MainActor.run { proxyAsset }
        let scale = await MainActor.run { displayScale }
        let scheme = await MainActor.run { colorScheme }
        let contrast = await MainActor.run { UIAccessibility.isDarkerSystemColorsEnabled }
        // 后台渲染（02 §7：不阻塞主线程；列表不读原图）
        let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            StickerRenderer.renderDisplayImage(asset: asset, role: role, appearance: scheme,
                                               increasedContrast: contrast, displayScale: scale,
                                               presentation: nil)
        }.value
        guard let rendered else { return }
        VisualRenderCache.storeImage(rendered, for: key)
        // 迟到结果只在 key 仍匹配时落地（快速切换防旧图闪现）
        await MainActor.run {
            if renderKey == key { displayImage = rendered }
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
