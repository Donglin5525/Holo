//
//  SpendingProjectVisualSection.swift
//  Holo
//
//  固定支出的贴纸接线（方案 01 §5.1，原型场景三 1:1）：
//  列表图标位与详情主视觉共用同一位置（spendingProject/primaryVisual）；
//  未设置素材恢复原分类图标；换图不改金额/流水/日均（02 §5 纯视觉提交）。
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

/// 列表图标位：有贴纸显示贴纸，否则原分类徽章（42pt 位不变，热区不变）
struct SpendingProjectIconSlot: View {
    let project: SpendingProject
    // 全工程不注入 managedObjectContext 环境（Repository 单例模式）——
    // 环境默认值是空模型临时 context，fetch 贴纸实体会抛 entityForName 异常闪退（11-17 真机实锤）。
    // 贴纸读取一律直连主栈 viewContext。

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

/// 详情主视觉区：顶部大贴纸 + 编辑外观 / 恢复分类图标（仅设置了贴纸时出现）
struct SpendingProjectVisualSection: View {
    let project: SpendingProject
    @State private var showMaker = false
    @State private var busy = false
    /// 贴纸写入不触发 SwiftUI 重算（Form 不监听视觉实体）——通知驱动 bump 强制重查
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
                .listRowBackground(Color.holoCardBackground)
            }
            Section {
                Button {
                    showMaker = true
                } label: {
                    Label("编辑外观 —— 拍照制作 / 从素材库选", systemImage: "sparkles")
                }
                Button(role: .destructive) {
                    restoreDefault()
                } label: {
                    Label("恢复分类图标", systemImage: "arrow.uturn.backward")
                }
            }
            .listRowBackground(Color.holoCardBackground)
            .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
                revisionBump += 1
            }
            .id(revisionBump)
            .sheet(isPresented: $showMaker) {
                StickerMakerView(ownerKind: SpendingProject.visualOwnerKind,
                                 ownerKey: project.visualOwnerKey ?? UUID().uuidString,
                                 slot: SpendingProject.visualSlot,
                                 expectedWinner: descriptor.winningRevisionID) { _ in }
            }
        } else {
            // 未设置素材：详情保持原样，仅在编辑区给一个「设置外观」入口
            Section {
                Button {
                    showMaker = true
                } label: {
                    Label("设置外观 —— 用自己的物品做图标", systemImage: "sparkles")
                }
            }
            .listRowBackground(Color.holoCardBackground)
            .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
                revisionBump += 1
            }
            .id(revisionBump)
            .sheet(isPresented: $showMaker) {
                StickerMakerView(ownerKind: SpendingProject.visualOwnerKind,
                                 ownerKey: project.visualOwnerKey ?? UUID().uuidString,
                                 slot: SpendingProject.visualSlot,
                                 expectedWinner: nil) { _ in }
            }
        }
    }

    /// 恢复默认：写 clear 版本（仅此 slot，不删素材）
    private func restoreDefault() {
        guard !busy, let ownerKey = project.visualOwnerKey else { return }
        busy = true
        let container = CoreDataStack.shared.persistentContainer
        Task {
            _ = try? await VisualCommitCoordinator.shared.commit(
                .applyPlacement(operationID: UUID(),
                                ownerKind: SpendingProject.visualOwnerKind,
                                ownerKey: ownerKey,
                                slot: SpendingProject.visualSlot,
                                expectedSlotWinnerRevisionID: project.resolvePrimaryVisual(in: CoreDataStack.shared.viewContext).winnerRevisionIDIfAny,
                                payload: .clear),
                in: container)
            await MainActor.run { busy = false }
        }
    }
}

extension ResolvedPlacement {
    /// 基线回执用：当前赢家的 revisionID（无赢家时 nil）
    var winnerRevisionIDIfAny: UUID? {
        if case .assetReady(let d) = self { return d.winningRevisionID }
        return nil
    }
}
