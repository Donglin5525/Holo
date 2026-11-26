//
//  SpendingProjectVisualSection.swift
//  Holo
//
//  固定支出融合外观渲染层（贴纸 / 品牌图标 / Emoji / Holo 经典图标 / 默认分类图标）
//  优先级：贴纸 > 自定义图标（sub_* 品牌图 / Emoji / 经典图标）> 消费分类图标
//

import SwiftUI
import CoreData
#if canImport(UIKit)
import UIKit
#endif

extension SpendingProject {
    static let visualOwnerKind = "spendingProject"
    static let visualSlot = "primaryVisual"

    /// 存量老数据 id 可能未写（@NSManaged 非 optional 底层仍可 nil）——
    /// 安全读，缺 id 的旧项目跳过贴纸解析、走自定义图标或分类图标，不崩
    var visualOwnerKey: String? {
        (value(forKey: "id") as? UUID)?.uuidString
    }

    func resolvePrimaryVisual(in context: NSManagedObjectContext) -> ResolvedPlacement {
        guard let visualOwnerKey else { return .none }
        return VisualAssetRepository.shared.resolvePlacement(ownerKind: Self.visualOwnerKind,
                                                             ownerKey: visualOwnerKey,
                                                             slot: Self.visualSlot,
                                                             in: context)
    }
}

/// 解析结果的赢家回执用（基线/恢复默认）
extension ResolvedPlacement {
    var winnerRevisionIDIfAny: UUID? {
        if case .assetReady(let d) = self { return d.winningRevisionID }
        return nil
    }
}

/// 统一图标渲染核：支持品牌原色图标（sub_*）、Emoji、Holo 经典单色图标
struct SpendingProjectCustomIconView: View {
    let iconKey: String
    var size: CGFloat = 42

    private var cornerRadius: CGFloat {
        size >= 56 ? HoloRadius.lg : HoloRadius.md
    }

    var body: some View {
        if iconKey.hasPrefix("sub_"), Self.hasBundleImage(named: iconKey) {
            Image(iconKey)
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
                .frame(width: size, height: size)
                .background(Color.holoToolInset)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if EmojiCatalog.isEmojiIcon(iconKey) {
            Text(iconKey)
                .font(.system(size: size * 0.5))
                .frame(width: size, height: size)
                .background(Color.holoToolInset)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            entityIconGlyph(iconKey, size: size * 0.48, color: .holoToolText)
                .frame(width: size, height: size)
                .background(Color.holoToolInset)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private static func hasBundleImage(named name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(named: name) != nil
        #else
        NSImage(named: name) != nil
        #endif
    }
}

/// 列表与详情共用的融合外观槽位（默认 42pt 列表位，详情可传 64pt）
struct SpendingProjectIconSlot: View {
    let project: SpendingProject
    var size: CGFloat = 42
    @State private var revisionBump = 0

    var body: some View {
        Group {
            let resolved = SpendingProjectRepository.shared.resolvePrimaryVisual(for: project)
            if case .assetReady(let descriptor) = resolved {
                VisualPlacementView(placement: .assetReady(descriptor), role: .icon)
                    .frame(width: size, height: size)
            } else if let customIcon = project.icon, !customIcon.isEmpty {
                SpendingProjectCustomIconView(iconKey: customIcon, size: size)
            } else {
                let category = project.categoryId.flatMap { FinanceRepository.shared.findCategory(by: $0) }
                if let category, !category.isDeleted {
                    CategoryIconBadge(category: category, diameter: size)
                } else {
                    CategoryIconBadge(iconName: "bag.fill", color: .holoToolTextSecondary, diameter: size)
                }
            }
        }
        .id(revisionBump)
        .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
            revisionBump += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .financeDataDidChange)) { _ in
            revisionBump += 1
        }
    }
}

/// 表单内融合外观预览槽（用于新建或编辑时即时预览已选贴纸/Emoji/经典图标）
struct SpendingProjectAppearancePreviewSlot: View {
    let selection: SpendingProjectAppearanceSelection
    var currentPlacement: ResolvedPlacement = .none
    var currentIcon: String? = nil
    var fallbackCategory: Category? = nil
    var size: CGFloat = 40

    var body: some View {
        switch selection {
        case .sticker(let assetID, let presentation):
            VisualPlacementView(
                placement: .assetReady(VisualDescriptor(
                    assetID: assetID,
                    winningRevisionID: assetID,
                    kind: .sticker,
                    presentation: presentation
                )),
                role: .icon
            )
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        case .icon(let key):
            SpendingProjectCustomIconView(iconKey: key, size: size)
        case .clearToDefault:
            defaultBadge
        case .unchanged:
            if case .assetReady(let descriptor) = currentPlacement {
                VisualPlacementView(placement: .assetReady(descriptor), role: .icon)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            } else if let currentIcon, !currentIcon.isEmpty {
                SpendingProjectCustomIconView(iconKey: currentIcon, size: size)
            } else {
                defaultBadge
            }
        }
    }

    @ViewBuilder
    private var defaultBadge: some View {
        if let fallbackCategory, !fallbackCategory.isDeleted {
            CategoryIconBadge(category: fallbackCategory, diameter: size)
        } else {
            Image(systemName: "creditcard")
                .holoIconSize(.md)
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: size, height: size)
                .background(Color.holoToolInset)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
    }
}
