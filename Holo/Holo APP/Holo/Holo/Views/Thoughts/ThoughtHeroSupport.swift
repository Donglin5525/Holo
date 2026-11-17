//
//  ThoughtHeroSupport.swift
//  Holo
//
//  想法头图接线（方案 01 §6，原型场景四 1:1）：上图是主角、下纸是叙事。
//  头图独立于正文附件与纸张；九种纸张照旧；无头图整段折叠不留空占位；
//  只换头图不触发文本 AI（纯视觉提交，02 §5.2）。
//

import SwiftUI
import CoreData

extension Thought {
    static let visualOwnerKind = "thought"
    static let visualSlot = "hero"

    var visualOwnerKey: String { id.uuidString }

    func resolveHeroVisual(in context: NSManagedObjectContext) -> ResolvedPlacement {
        VisualAssetRepository.shared.resolvePlacement(ownerKind: Self.visualOwnerKind,
                                                      ownerKey: visualOwnerKey,
                                                      slot: Self.visualSlot,
                                                      in: context)
    }
}

/// 编辑器/详情的头图区（240–320pt，贴纸完整显示、照片按取景意图）
struct ThoughtHeroView: View {
    let placement: ResolvedPlacement

    var body: some View {
        if case .assetReady(let descriptor) = placement {
            VisualPlacementView(placement: .assetReady(descriptor), role: .hero)
                .frame(height: 264)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ThoughtLayout.contentInset)
        }
        // 无头图：整段折叠，不留空白占位（01 §6.2）
    }
}

/// 列表卡的头图预览（120–180pt；紧凑模式由列表层用 .icon 角色缩略）
struct ThoughtHeroListPreview: View {
    let placement: ResolvedPlacement

    var body: some View {
        if case .assetReady(let descriptor) = placement {
            VisualPlacementView(placement: .assetReady(descriptor), role: .list)
                .frame(height: 148)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 8)
        }
    }
}
