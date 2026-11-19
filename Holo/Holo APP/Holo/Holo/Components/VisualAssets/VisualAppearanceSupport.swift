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

/// 外观候选：表单场景暂存、保存时统一绑定（东林 11-18 拍板：全模块统一 B 逻辑——
/// 草稿随「保存」生效，取消丢弃；详情直达场景仍立即生效）
enum VisualAppearanceDraft: Equatable {
    case none
    case set(assetID: UUID, presentation: VisualPlacementPayload.Presentation?)
    case cleared

    /// 保存收口：给定 owner 绑定（新项目用新建的 key）。
    /// 抛错（含 conflict）：失败如实上抛由调用方提示，不静默吞（B10）
    func commit(ownerKind: String, ownerKey: String, slot: String,
                expectedSlotWinnerRevisionID: UUID? = nil,
                in container: NSPersistentContainer) async throws {
        switch self {
        case .none:
            return
        case .set(let assetID, let presentation):
            _ = try await VisualCommitCoordinator.shared.commit(
                .applyPlacement(operationID: UUID(), ownerKind: ownerKind, ownerKey: ownerKey,
                                slot: slot, expectedSlotWinnerRevisionID: expectedSlotWinnerRevisionID,
                                payload: .setAsset(.asset(assetID), presentation: presentation)),
                in: container)
        case .cleared:
            _ = try await VisualCommitCoordinator.shared.commit(
                .applyPlacement(operationID: UUID(), ownerKind: ownerKind, ownerKey: ownerKey,
                                slot: slot, expectedSlotWinnerRevisionID: expectedSlotWinnerRevisionID,
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
    /// 动态解析闭包：通知刷新时重新查库，避免父表单传入的快照值过期
    var placementProvider: (() -> ResolvedPlacement)? = nil
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
        // 通知只驱动 body 重算（bump 状态变化），不再 .id(bump) 销毁重建整行——
        // 行身份稳定是「首帧同步命中缓存」不闪灰块的前提（B2 关联项）
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

    private var resolvedCurrent: ResolvedPlacement? { placementProvider?() ?? currentPlacement }

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
    /// 长按管理动作（nil=无长按菜单；东林 11-19 需求 4：选择器里也能编辑/删除贴纸）
    var onManage: ((VisualAsset, ManageAction) -> Void)? = nil

    enum ManageAction {
        case edit
        case delete
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                  spacing: 10) {
            ForEach(assets.renderable, id: \.objectID) { asset in
                cell(asset)
            }
        }
        .animation(nil, value: selectedAssetID)
    }

    @ViewBuilder
    private func cell(_ asset: VisualAsset) -> some View {
        let assetID = (asset.value(forKey: "id") as? UUID) ?? UUID()
        let isSelected = selectedAssetID == assetID
        let isInUse = inUseAssetID == assetID
        let card = cardLabel(asset, assetID: assetID, isSelected: isSelected, isInUse: isInUse)
        // 单击=选中（B10 语义）；长按=编辑/删除菜单（primaryAction 模式两者不冲突）
        if let onManage {
            Menu {
                Button {
                    onManage(asset, .edit)
                } label: {
                    Label(String(localized: "编辑贴纸"), systemImage: "slider.horizontal.3")
                }
                Button(role: .destructive) {
                    onManage(asset, .delete)
                } label: {
                    Label(String(localized: "删除贴纸"), systemImage: "trash")
                }
            } label: {
                card
            } primaryAction: {
                selectedAssetID = assetID
            }
        } else {
            Button {
                // 单击=选中高亮，底部主按钮确认（B10 修复：取消选中分支不再误调 onPick）
                selectedAssetID = assetID
            } label: {
                card
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func cardLabel(_ asset: VisualAsset, assetID: UUID, isSelected: Bool, isInUse: Bool) -> some View {
        let descriptor = VisualDescriptor(assetID: assetID, winningRevisionID: assetID,
                                          kind: VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) ?? .sticker,
                                          presentation: asset.defaultPresentation)
        let isFav = (asset.value(forKey: "isFavorite") as? Bool) == true
        VStack(spacing: 4) {
            VisualAssetView(descriptor: descriptor, role: .icon)
                .frame(height: 84)
            Text(asset.resolvedDisplayName)
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
        .overlay(alignment: .topLeading) {
            if isFav {
                Image(systemName: "star.fill")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color.holoStarTint)
                    .padding(6)
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
}

// MARK: - 当前外观卡（选择器顶部）

struct VisualCurrentAppearanceCard: View {
    let currentPlacement: ResolvedPlacement
    var fallbackIcon: String = "bag.fill"
    /// 紧凑条（44pt 预览）：外观页顶部用，把空间让给贴纸网格
    var compact: Bool = false
    /// 恢复默认：编辑场景直接 clear（立即生效）；新增场景回执 draft=cleared
    var onRestoreDefault: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            currentThumb
                .frame(width: thumbSide, height: thumbSide)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "当前外观"))
                    .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
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
        .padding(compact ? 8 : 12)
        .background(Color.holoToolSurface)
        .cornerRadius(compact ? 10 : 12)
    }

    private var thumbSide: CGFloat { compact ? 44 : 56 }

    @ViewBuilder
    private var currentThumb: some View {
        if case .assetReady(let descriptor) = currentPlacement {
            VisualPlacementView(placement: .assetReady(descriptor), role: .icon)
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: compact ? 18 : 22))
                .foregroundColor(.holoToolTextSecondary)
                .frame(width: thumbSide, height: thumbSide)
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


// MARK: - 素材管理动作（素材库/选择器共用）

enum VisualAssetManagement {

    /// 彻底删除：墓碑 + 清 Binary（同事务）；派生缓存按 assetID 精准失效 + 变更广播。
    /// 供「我的贴纸」与选择器长按删除共用（东林 11-19 需求 4）
    static func hardDelete(asset: VisualAsset, in context: NSManagedObjectContext) throws {
        guard let assetID = asset.value(forKey: "id") as? UUID else { return }
        try context.performAndWait {
            _ = try VisualAssetRepository.shared.writeTombstone(operationID: UUID(), assetID: assetID, in: context)
            for key in ["sourceData", "maskData", "contentData", "thumbnailData"] {
                asset.setValue(nil, forKey: key)
            }
            asset.setValue("recordOnly", forKey: "libraryVisibility")
            try context.save()
        }
        VisualRenderCache.removeImages(assetID: assetID)
        let generation = VisualCommitCoordinator.shared.scopeGeneration
        NotificationCenter.default.post(
            name: .visualAssetsDidChange,
            object: nil,
            userInfo: [
                "scopeGeneration": generation,
                "assetIDs": [assetID.uuidString],
                "changeKind": "delete",
            ])
    }

    /// 批量彻底删除（素材库多选模式）
    static func hardDeleteBatch(assets: [VisualAsset], in context: NSManagedObjectContext) throws {
        var deletedIDs: [UUID] = []
        try context.performAndWait {
            for asset in assets {
                guard let assetID = asset.value(forKey: "id") as? UUID else { continue }
                _ = try VisualAssetRepository.shared.writeTombstone(operationID: UUID(), assetID: assetID, in: context)
                for key in ["sourceData", "maskData", "contentData", "thumbnailData"] {
                    asset.setValue(nil, forKey: key)
                }
                asset.setValue("recordOnly", forKey: "libraryVisibility")
                deletedIDs.append(assetID)
            }
            if context.hasChanges { try context.save() }
        }
        for id in deletedIDs {
            VisualRenderCache.removeImages(assetID: id)
        }
        let generation = VisualCommitCoordinator.shared.scopeGeneration
        NotificationCenter.default.post(
            name: .visualAssetsDidChange,
            object: nil,
            userInfo: [
                "scopeGeneration": generation,
                "assetIDs": deletedIDs.map(\.uuidString),
                "changeKind": "delete",
            ])
    }
}

// MARK: - 贴纸分组存储 & 筛选模型

enum VisualAssetFilter: Hashable {
    case recent
    case all
    case favorite
    case group(String)
}

enum VisualAssetGroupStore {
    private static let storageKey = "holo.visual.customGroups.v1"

    /// 读取所有分组（本地保序自定义组 + Core Data 中已同步贴纸的组名并集）
    static func allGroups(in context: NSManagedObjectContext) -> [String] {
        var result = savedLocalGroups()
        var seen = Set(result)
        let req = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        req.predicate = NSPredicate(format: "libraryVisibility == %@", "visible")
        if let assets = try? context.fetch(req) {
            for asset in assets {
                if let g = asset.groupName, !seen.contains(g) {
                    seen.insert(g)
                    result.append(g)
                }
            }
        }
        return result
    }

    static func visibleStickerCount(in context: NSManagedObjectContext) -> Int {
        guard let entities = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName,
              entities["VisualAsset"] != nil else { return 0 }
        let req = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        req.predicate = NSPredicate(format: "libraryVisibility == %@", "visible")
        return (try? context.count(for: req)) ?? 0
    }

    @discardableResult
    static func addGroup(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var groups = savedLocalGroups()
        if !groups.contains(name) {
            groups.append(name)
            UserDefaults.standard.set(groups, forKey: storageKey)
        }
        return name
    }

    static func renameGroup(from oldName: String, to rawNewName: String, in context: NSManagedObjectContext) {
        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName else { return }
        var groups = savedLocalGroups()
        if let idx = groups.firstIndex(of: oldName) {
            groups[idx] = newName
        } else if !groups.contains(newName) {
            groups.append(newName)
        }
        // 去重保序
        var unique: [String] = []
        for g in groups where !unique.contains(g) { unique.append(g) }
        UserDefaults.standard.set(unique, forKey: storageKey)

        let req = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        req.predicate = NSPredicate(format: "libraryVisibility == %@", "visible")
        if let assets = try? context.fetch(req) {
            for asset in assets where asset.groupName == oldName {
                asset.groupName = newName
                asset.setValue(Date(), forKey: "metadataUpdatedAt")
            }
            if context.hasChanges { try? context.save() }
        }
        NotificationCenter.default.post(name: .visualAssetsDidChange, object: nil)
    }

    /// 删除分组：将组内贴纸移回「未分组」，不删贴纸本身
    static func deleteGroup(_ name: String, in context: NSManagedObjectContext) {
        var groups = savedLocalGroups()
        groups.removeAll { $0 == name }
        UserDefaults.standard.set(groups, forKey: storageKey)

        let req = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        req.predicate = NSPredicate(format: "libraryVisibility == %@", "visible")
        if let assets = try? context.fetch(req) {
            for asset in assets where asset.groupName == name {
                asset.groupName = nil
                asset.setValue(Date(), forKey: "metadataUpdatedAt")
            }
            if context.hasChanges { try? context.save() }
        }
        NotificationCenter.default.post(name: .visualAssetsDidChange, object: nil)
    }

    /// 按筛选条件与搜索词查询可见贴纸（选择器与素材库共用）
    static func fetchAssets(filter: VisualAssetFilter, searchText: String, in context: NSManagedObjectContext) -> [VisualAsset] {
        guard let entities = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName,
              entities["VisualAsset"] != nil else { return [] }
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "libraryVisibility == %@", "visible")
        switch filter {
        case .recent:
            request.sortDescriptors = [NSSortDescriptor(key: "metadataUpdatedAt", ascending: false)]
            request.fetchLimit = 30
        case .all, .group:
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        case .favorite:
            request.predicate = NSPredicate(format: "libraryVisibility == %@ AND isFavorite == YES", "visible")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        }
        var fetched = (try? context.fetch(request)) ?? []
        if case .group(let groupName) = filter {
            fetched = fetched.filter { $0.groupName == groupName }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            fetched = fetched.filter { asset in
                asset.resolvedDisplayName.localizedCaseInsensitiveContains(keyword)
                    || (asset.groupName?.localizedCaseInsensitiveContains(keyword) == true)
            }
        }
        return fetched
    }

    private static func savedLocalGroups() -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }
}

// MARK: - 共用搜索 + 分组胶囊筛选条（选择器与素材库共用）

struct VisualAssetFilterBar: View {
    @Binding var searchText: String
    @Binding var filter: VisualAssetFilter
    let groups: [String]
    var onAddGroup: (() -> Void)? = nil
    var onRenameGroup: ((String) -> Void)? = nil
    var onDeleteGroup: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolTextSecondary)
                TextField(String(localized: "搜索贴纸名称或分组"), text: $searchText)
                    .font(.system(size: 13.5))
                    .foregroundColor(.holoToolText)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.holoToolSurface)
            .cornerRadius(11)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    filterChip(title: String(localized: "常用"), target: .recent)
                    filterChip(title: String(localized: "全部"), target: .all)
                    filterChip(title: String(localized: "收藏"), icon: "star.fill", target: .favorite)

                    ForEach(groups, id: \.self) { group in
                        groupChip(group)
                    }

                    if let onAddGroup {
                        Button(action: onAddGroup) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(String(localized: "新建分组"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.holoToolTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.holoToolSurface)
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.holoToolBorder, style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func filterChip(title: String, icon: String? = nil, target: VisualAssetFilter) -> some View {
        let selected = filter == target
        return Button {
            filter = target
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundColor(selected ? .holoToolOnAction : .holoToolText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? Color.holoToolAction : Color.holoToolSurface)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.clear : Color.holoToolBorder, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func groupChip(_ group: String) -> some View {
        let target = VisualAssetFilter.group(group)
        let selected = filter == target
        let labelView = Text(group)
            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
            .lineLimit(1)
            .foregroundColor(selected ? .holoToolOnAction : .holoToolText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? Color.holoToolAction : Color.holoToolSurface)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Color.clear : Color.holoToolBorder, lineWidth: 0.7)
            )

        if onRenameGroup != nil || onDeleteGroup != nil {
            Menu {
                if let onRenameGroup {
                    Button { onRenameGroup(group) } label: {
                        Label(String(localized: "重命名分组"), systemImage: "pencil")
                    }
                }
                if let onDeleteGroup {
                    Button(role: .destructive) { onDeleteGroup(group) } label: {
                        Label(String(localized: "删除分组"), systemImage: "trash")
                    }
                }
            } label: {
                labelView
            } primaryAction: {
                filter = target
            }
        } else {
            Button { filter = target } label: { labelView }
                .buttonStyle(.plain)
        }
    }
}
