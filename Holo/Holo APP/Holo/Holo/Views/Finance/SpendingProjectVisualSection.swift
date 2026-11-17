//
//  SpendingProjectVisualSection.swift
//  Holo
//
//  固定支出详情的只读主视觉（2026-11-17 交互重设计 · ios-design 方案 · 东林拍板）：
//  详情页只回答「这是什么、花了多少」——外观入口全部归编辑表单（一处收口），
//  本 Section 有贴纸才渲染，无贴纸整段消失不留占位；刷新靠 .visualAssetsDidChange。
//

import SwiftUI
import CoreData

extension SpendingProject {
    static let visualOwnerKind = "spendingProject"
    static let visualSlot = "primaryVisual"

    /// 存量老数据 id 可能未写（@NSManaged 非 optional 底层仍可 nil）——
    /// 安全读，缺 id 的旧项目跳过贴纸解析、走原分类图标，不崩
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

/// 列表图标位：有贴纸显示贴纸，否则原分类徽章（42pt 位不变，热区不变）
struct SpendingProjectIconSlot: View {
    let project: SpendingProject

    var body: some View {
        let resolved = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext)
        if case .assetReady(let descriptor) = resolved {
            VisualPlacementView(placement: .assetReady(descriptor), role: .icon)
                .frame(width: 42, height: 42)
        } else {
            let category = project.categoryId.flatMap { FinanceRepository.shared.findCategory(by: $0) }
            if let category, !category.isDeleted {
                CategoryIconBadge(category: category, diameter: 42)
            } else {
                CategoryIconBadge(iconName: "bag.fill", color: .holoTextSecondary, diameter: 42)
            }
        }
    }
}

struct SpendingProjectVisualSection: View {
    let project: SpendingProject
    @State private var revisionBump = 0

    var body: some View {
        let resolved = project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext)
        if case .assetReady(let descriptor) = resolved {
            Section {
                VStack(spacing: 8) {
                    VisualPlacementView(placement: .assetReady(descriptor), role: .hero)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                    Text(project.name)
                        .font(.holoTitle3)
                        .foregroundColor(.holoTextPrimary)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.holoCardBackground)
            .id(revisionBump)
            .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
                revisionBump += 1
            }
        }
        // 无贴纸：整段折叠（占位/空区都不留）；pending 等状态由 VisualPlacementView 内建占位承担
    }
}
