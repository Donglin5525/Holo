//
//  VisualAppearanceSupport.swift
//  Holo
//
//  外观重设计（2026-11-17 ios-design 方案 · 东林拍板）共用组件：
//  - VisualAppearanceDraft：外观候选值（新增表单场景暂存，保存时绑定；
//    编辑场景不用 draft——选完立即生效）
//  - VisualAppearanceFormRow：表单「外观」行（42pt 缩览 + 标题 + 当前值 + chevron）
//  - VisualAssetGrid：素材网格（选择器与「我的贴纸」共用；选中态/使用中态）
//  - VisualCurrentAppearanceCard：选择器顶部「当前外观」卡（含恢复默认）
//

import SwiftUI
import CoreData

// MARK: - 候选值（新增表单场景）

/// 外观候选：新项目还没有 id，选择完暂存、保存时绑定（东林拍板的「立即生效」
/// 在编辑场景即时 applyPlacement；新增场景对象不存在，只能保存收口——物理限制）
enum VisualAppearanceDraft: Equatable {
    case none
    case set(assetID: UUID, presentation: VisualPlacementPayload.Presentation?)
    case cleared

    /// 保存收口：给定 owner 绑定（新项目用新建的 key）
    func commit(ownerKind: String, ownerKey: String, slot: String,
                in container: NSPersistentContainer) async {
        switch self {
        case .none:
            return
        case .set(let assetID, let presentation):
            _ = try? await VisualCommitCoordinator.shared.commit(
                .applyPlacement(operationID: UUID(), ownerKind: ownerKind, ownerKey: ownerKey,
                                slot: slot, expectedSlotWinnerRevisionID: nil,
                                payload: .setAsset(.asset(assetID), presentation: presentation)),
                in: container)
        case .cleared:
            _ = try? await VisualCommitCoordinator.shared.commit(
                .applyPlacement(operationID: UUID(), ownerKind: ownerKind, ownerKey: ownerKey,
                                slot: slot, expectedSlotWinnerRevisionID: nil,
                                payload: .clear),
                in: container)
        }
    }
}

// MARK: - 表单「外观」行

/// 表单外观行：缩览=候选(新增) > 当前生效贴纸 > 分类徽章；点行弹外观选择器
struct VisualAppearanceFormRow: View {
    let title: String = String(localized: "外观")
    /// 新增场景的候选（nil=编辑场景，显示当前生效值）
    var draft: VisualAppearanceDraft?
    /// 编辑场景：当前生效位置（nil=新增场景）
    var currentPlacement: ResolvedPlacement?
    /// 新增场景的分类图标名（未选贴纸时的默认徽章）
    var fallbackIcon: String = "bag.fill"
    var onTap: () -> Void

    @State private var bump = 0

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HoloSpacing.md) {
                thumbnail
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(valueText)
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(bump)
        .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
            bump += 1
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        // 优先级：候选 > 当前生效 > 分类徽章
        if case .set(let assetID, let presentation) = draft {
            VisualPlacementView(placement: .assetReady(VisualDescriptor(
                assetID: assetID, winningRevisionID: assetID,
                kind: .sticker, presentation: presentation)), role: .icon)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if case .assetReady(let descriptor) = resolvedCurrent {
            VisualPlacementView(placement: .assetReady(descriptor), role: .icon)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: 18))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 42, height: 42)
                .background(Color.holoToolInset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var resolvedCurrent: ResolvedPlacement? { currentPlacement }

    private var valueText: String {
        if case .set = draft { return String(localized: "已选贴纸 · 保存后生效") }
        if case .cleared = draft { return String(localized: "默认图标 · 保存后生效") }
        if case .assetReady = resolvedCurrent { return String(localized: "正在使用贴纸") }
        return String(localized: "默认分类图标")
    }
}

// MARK: - 素材网格（选择器/素材库共用）

struct VisualAssetGrid: View {
    let assets: [VisualAsset]
    /// 当前选中（选择器点选态）
    @Binding var selectedAssetID: UUID?
    /// 当前生效（「使用中」chip，不预选）
    var inUseAssetID: UUID?
    var onPick: (VisualAsset) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                  spacing: 10) {
            ForEach(assets.renderable, id: \.objectID) { asset in
                cell(asset)
            }
        }
    }

    private func cell(_ asset: VisualAsset) -> some View {
        let assetID = (asset.value(forKey: "id") as? UUID) ?? UUID()
        let isSelected = selectedAssetID == assetID
        let isInUse = inUseAssetID == assetID
        let descriptor = VisualDescriptor(assetID: assetID, winningRevisionID: assetID,
                                          kind: VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) ?? .sticker,
                                          presentation: nil)
        return Button {
            selectedAssetID = isSelected ? nil : assetID
            if isSelected { onPick(asset) }
        } label: {
            VStack(spacing: 4) {
                VisualAssetView(descriptor: descriptor, role: .icon)
                    .frame(height: 84)
                Text(defaultName(asset))
                    .font(.system(size: 11))
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(Color.holoToolSurface)
            .cornerRadius(14)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.holoToolAction, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    ZStack {
                        Circle().fill(Color.holoToolAction).frame(width: 18, height: 18)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.holoToolOnAction)
                    }
                    .padding(5)
                } else if isInUse {
                    Text(String(localized: "使用中"))
                        .font(.system(size: 10))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.holoToolInset)
                        .cornerRadius(6)
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func defaultName(_ asset: VisualAsset) -> String {
        let name = asset.value(forKey: "displayName") as? String
        if let name, !name.isEmpty { return name }
        return String(localized: "贴纸")
    }
}

// MARK: - 当前外观卡（选择器顶部）

struct VisualCurrentAppearanceCard: View {
    let currentPlacement: ResolvedPlacement
    var fallbackIcon: String = "bag.fill"
    /// 恢复默认：编辑场景直接 clear（立即生效）；新增场景回执 draft=cleared
    var onRestoreDefault: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            currentThumb
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "当前外观"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoToolText)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if case .assetReady = currentPlacement {
                Button(String(localized: "恢复默认"), action: onRestoreDefault)
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(12)
        .background(Color.holoToolSurface)
        .cornerRadius(12)
    }

    @ViewBuilder
    private var currentThumb: some View {
        if case .assetReady(let descriptor) = currentPlacement {
            VisualPlacementView(placement: .assetReady(descriptor), role: .icon)
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: 22))
                .foregroundColor(.holoToolTextSecondary)
                .frame(width: 56, height: 56)
                .background(Color.holoToolInset)
        }
    }

    private var statusText: String {
        if case .assetReady = currentPlacement {
            return String(localized: "正在使用贴纸")
        }
        if case .pending = currentPlacement {
            return String(localized: "贴纸同步中")
        }
        return String(localized: "分类图标，还没设置贴纸")
    }
}
