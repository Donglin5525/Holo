//
//  VisualAssetLibraryView.swift
//  Holo
//
//  「我的贴纸」素材库（2026-11-20 交互与分组升级）：
//  - 与外观选择器共用 VisualAssetFilterBar：搜索 + 常用/全部/收藏/自定义分组胶囊
//  - 单击贴纸进「贴纸详情」大图预览（含名称/分组编辑、真实名称的使用位置、快捷操作）
//  - 长按贴纸提供快捷菜单；右上角「选择」进入批量归组 / 批量删除模式
//  - 底部三入口直拉系统选择器（相机/相册/文件），拿到图直接栈内 push 确认页（allowsPositionAdjust: false）
//  - 确认页保存的名称、分组、纸边风格与厚度全部写入 VisualAsset 资产元数据（零 Schema 改动、CloudKit 同步）
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct VisualAssetLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    private var context: NSManagedObjectContext { CoreDataStack.shared.viewContext }

    enum Tab: String, CaseIterable {
        case recent = "最近使用"
        case all = "全部"
        case favorite = "收藏"
    }

    @State private var filter: VisualAssetFilter = .all
    @State private var searchText = ""
    @State private var groups: [String] = []
    @State private var assets: [VisualAsset] = []

    /// 批量管理模式
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false

    /// 单项操作目标
    @State private var detailTarget: VisualAsset?
    @State private var renameTarget: VisualAsset?
    @State private var renameText = ""
    @State private var deleteTarget: VisualAsset?
    @State private var toast: String?

    /// 分组管理弹窗
    @State private var showNewGroupAlert = false
    @State private var newGroupName = ""
    @State private var renameGroupTarget: String?
    @State private var renameGroupText = ""
    @State private var deleteGroupTarget: String?

    /// 媒体采集：三入口直拉系统选择器（互斥）
    @State private var activeMediaSource: VisualMediaSource?
    @State private var cameraDenied = false
    /// 确认页模型：拿到图后栈内 push（跳过选择器首屏，拆套娃）
    @State private var confirmModel: StickerMakerModel?
    @State private var exportShareItem: ExportShareItem?

    struct ExportShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                VisualAssetFilterBar(
                    searchText: $searchText,
                    filter: $filter,
                    groups: groups,
                    onAddGroup: { showNewGroupAlert = true },
                    onRenameGroup: { group in
                        renameGroupTarget = group
                        renameGroupText = group
                    },
                    onDeleteGroup: { group in
                        deleteGroupTarget = group
                    }
                )
                .padding(.horizontal, 16)

                if assets.isEmpty {
                    emptyState
                } else {
                    grid
                }

                if isSelecting {
                    batchActionBar
                } else {
                    // 底部三入口：直拉对应系统选择器（01 §3.1：与拍照同为一等公民）
                    HStack(spacing: 8) {
                        libraryButton(icon: "camera", title: String(localized: "拍照制作")) { launchCamera() }
                        libraryButton(icon: "photo.on.rectangle", title: String(localized: "从相册选")) {
                            launchPhotoLibrary()
                        }
                        libraryButton(icon: "doc", title: String(localized: "从文件导入")) {
                            activeMediaSource = .document
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
            }
            .padding(.top, 6)
            .background(Color.holoToolBackground)
            .navigationTitle(isSelecting
                             ? String(localized: "已选 \(selectedIDs.count) 张")
                             : String(localized: "我的贴纸"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSelecting {
                        Button(String(localized: "取消")) {
                            exitSelectionMode()
                        }
                    } else {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                        .accessibilityLabel(Text("关闭"))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isSelecting {
                        Button(selectedIDs.count == assets.count && !assets.isEmpty
                               ? String(localized: "取消全选")
                               : String(localized: "全选")) {
                            toggleSelectAll()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .disabled(assets.isEmpty)
                    } else if !assets.isEmpty {
                        Button(String(localized: "选择")) {
                            isSelecting = true
                            selectedIDs.removeAll()
                        }
                        .font(.system(size: 14, weight: .medium))
                    }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { confirmModel != nil },
                set: { if !$0 { confirmModel = nil } }
            )) {
                if let confirmModel {
                    StickerConfirmEditorView(model: confirmModel,
                                             useTitle: String(localized: "保存到我的贴纸"),
                                             supportsPhotoMode: false,
                                             allowsPositionAdjust: false) { _, _ in
                        self.confirmModel = nil
                        reload()
                    }
                }
            }
        }
        .visualMediaPresenter(activeSource: $activeMediaSource) { data in
            await startConfirm(with: data)
        }
        .alert(String(localized: "无法访问相机"), isPresented: $cameraDenied) {
            Button(String(localized: "去设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "请在系统设置里允许 Holo 使用相机，或改用相册/文件导入"))
        }
        .alert(String(localized: "新建分组"), isPresented: $showNewGroupAlert) {
            TextField(String(localized: "分组名称，如：数码、咖啡"), text: $newGroupName)
            Button(String(localized: "取消"), role: .cancel) { newGroupName = "" }
            Button(String(localized: "创建")) {
                if let created = VisualAssetGroupStore.addGroup(newGroupName) {
                    reload()
                    filter = .group(created)
                }
                newGroupName = ""
            }
        }
        .alert(String(localized: "重命名分组"), isPresented: Binding(
            get: { renameGroupTarget != nil },
            set: { if !$0 { renameGroupTarget = nil } }
        )) {
            TextField(String(localized: "新分组名称"), text: $renameGroupText)
            Button(String(localized: "取消"), role: .cancel) { renameGroupTarget = nil }
            Button(String(localized: "保存")) {
                if let old = renameGroupTarget {
                    let trimmed = renameGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
                    VisualAssetGroupStore.renameGroup(from: old, to: trimmed, in: context)
                    if case .group(let current) = filter, current == old, !trimmed.isEmpty {
                        filter = .group(trimmed)
                    }
                }
                renameGroupTarget = nil
                reload()
            }
        }
        .alert(String(localized: "删除分组「\(deleteGroupTarget ?? "")」？"), isPresented: Binding(
            get: { deleteGroupTarget != nil },
            set: { if !$0 { deleteGroupTarget = nil } }
        )) {
            Button(String(localized: "取消"), role: .cancel) { deleteGroupTarget = nil }
            Button(String(localized: "删除分组"), role: .destructive) {
                if let target = deleteGroupTarget {
                    VisualAssetGroupStore.deleteGroup(target, in: context)
                    if case .group(let current) = filter, current == target {
                        filter = .all
                    }
                }
                deleteGroupTarget = nil
                reload()
            }
        } message: {
            Text(String(localized: "不会删除贴纸本身，组内贴纸会保留在「全部」中。"))
        }
        .alert(String(localized: "彻底删除这 \(selectedIDs.count) 张贴纸？"), isPresented: $showBatchDeleteConfirm) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "彻底删除"), role: .destructive) {
                performBatchDelete()
            }
        } message: {
            Text(String(localized: "所有使用位置都会失去这些贴纸并回退到默认图标，此操作不可撤销。"))
        }
        .task { reload() }
        .onChange(of: filter) { _ in reload() }
        .onChange(of: searchText) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
            reload()
        }
        .sheet(item: $detailTarget) { asset in
            StickerAssetDetailSheet(
                asset: asset,
                groups: groups,
                usages: VisualAssetUsageResolver.resolveUsages(for: asset, in: context),
                onToggleFavorite: { toggleFavorite(asset) },
                onRename: { newName in
                    asset.setValue(newName.isEmpty ? nil : newName, forKey: "displayName")
                    asset.setValue(Date(), forKey: "metadataUpdatedAt")
                    try? context.save()
                    reload()
                },
                onChangeGroup: { newGroup in
                    assignGroup(newGroup, to: [asset])
                },
                onCreateGroupAndAssign: { rawName in
                    if let created = VisualAssetGroupStore.addGroup(rawName) {
                        assignGroup(created, to: [asset])
                    }
                },
                onEdit: {
                    detailTarget = nil
                    editAsset(asset)
                },
                onRemake: {
                    detailTarget = nil
                    remake(asset)
                },
                onExport: {
                    detailTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        exportPNG(asset)
                    }
                },
                onHide: {
                    detailTarget = nil
                    asset.setValue("hidden", forKey: "libraryVisibility")
                    try? context.save()
                    reload()
                },
                onDelete: {
                    detailTarget = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        deleteTarget = asset
                    }
                }
            )
        }
        .sheet(item: $renameTarget) { asset in
            renameSheet(asset)
        }
        .sheet(item: $exportShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("彻底删除这张贴纸？", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("取消", role: .cancel) {}
            Button("彻底删除", role: .destructive) {
                if let target = deleteTarget { hardDelete(target) }
            }
        } message: {
            Text("所有使用位置（包括其他设备尚未同步到的）都会失去这张素材。已显示的记录会回退，此操作不可撤销。")
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - 采集 → 确认页（拆套娃：跳过选择器首屏直达制作）

    private func startConfirm(with data: Data, editing asset: VisualAsset? = nil) async {
        let model = StickerMakerModel()
        if let asset {
            // 编辑模式：载入已抠好的主体+遮罩，并完整回显名称、分组、默认纸边
            let subjectData = (asset.value(forKey: "contentData") as? Data) ?? data
            let loaded = model.loadEdited(subjectData: subjectData,
                                          maskData: asset.value(forKey: "maskData") as? Data)
            if loaded {
                model.editTargetAssetID = asset.value(forKey: "id") as? UUID
                model.name = (asset.value(forKey: "displayName") as? String) ?? ""
                model.groupName = asset.groupName
                let meta = asset.visualMetadata
                model.borderStyle = meta.resolvedBorderStyle ?? .adaptivePaper
                model.borderWeight = meta.resolvedBorderWeight ?? .standard
                if let source = asset.value(forKey: "sourceData") as? Data {
                    model.preservedSource = (source, (asset.value(forKey: "sourceUTType") as? String) ?? UTType.png.identifier)
                }
            } else {
                await model.ingestSmart(data: data)
            }
        } else {
            if case .group(let currentGroup) = filter {
                model.groupName = currentGroup
            }
            await model.ingestSmart(data: data)
        }
        confirmModel = model
    }

    /// 「重新制作一份」：载入原图重做（无原图如实提示）
    private func remake(_ asset: VisualAsset) {
        guard let sourceData = asset.value(forKey: "sourceData") as? Data else {
            showToast("这张素材没有可重做的原图")
            return
        }
        Task { await startConfirm(with: sourceData) }
    }

    private func launchCamera() {
        Task {
            if await VisualMediaAcquisition.requestCameraAccess() {
                activeMediaSource = .camera
            } else {
                cameraDenied = true
            }
        }
    }

    private func launchPhotoLibrary() {
        Task {
            await PhotoLibraryImageLoader.requestLibraryAccessIfNeeded()
            activeMediaSource = .photoLibrary
        }
    }

    // MARK: - 数据与批量操作

    private func reload() {
        groups = VisualAssetGroupStore.allGroups(in: context)
        if case .group(let g) = filter, !groups.contains(g) {
            filter = .all
        }
        assets = VisualAssetGroupStore.fetchAssets(filter: filter, searchText: searchText, in: context)
        let validIDs = Set(assets.compactMap { $0.value(forKey: "id") as? UUID })
        selectedIDs = selectedIDs.intersection(validIDs)
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func toggleSelectAll() {
        let allIDs = Set(assets.compactMap { $0.value(forKey: "id") as? UUID })
        if selectedIDs.count == allIDs.count {
            selectedIDs.removeAll()
        } else {
            selectedIDs = allIDs
        }
    }

    private func selectedAssets() -> [VisualAsset] {
        assets.renderable.filter { asset in
            guard let id = asset.value(forKey: "id") as? UUID else { return false }
            return selectedIDs.contains(id)
        }
    }

    private func assignGroup(_ group: String?, to targets: [VisualAsset]) {
        for asset in targets {
            asset.groupName = group
            asset.setValue(Date(), forKey: "metadataUpdatedAt")
        }
        if context.hasChanges { try? context.save() }
        NotificationCenter.default.post(name: .visualAssetsDidChange, object: nil)
        reload()
    }

    private func performBatchDelete() {
        let targets = selectedAssets()
        guard !targets.isEmpty else { return }
        do {
            try VisualAssetManagement.hardDeleteBatch(assets: targets, in: context)
            exitSelectionMode()
            reload()
            showToast(String(localized: "已删除 \(targets.count) 张贴纸"))
        } catch {
            showToast(String(localized: "删除没有完成，请重试"))
        }
    }

    private func toggleFavorite(_ asset: VisualAsset) {
        asset.setValue(!(asset.value(forKey: "isFavorite") as? Bool ?? false), forKey: "isFavorite")
        asset.setValue(Date(), forKey: "metadataUpdatedAt")
        try? context.save()
        reload()
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if toast == message {
                withAnimation { toast = nil }
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        Group {
            if searchText.isEmpty, case .favorite = filter {
                // 收藏为空：一句话留白（审美七项 P5）；其余说明性空态保持工具页原有样式
                HoloQuietEmptyState(
                    line: "遇到喜欢的，\n点星标留下来。",
                    topSpacing: .flexible
                )
            } else {
                VStack(spacing: 10) {
                    Image(systemName: searchText.isEmpty ? "smallcircle.filled.circle" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.holoToolTextSecondary)
                    if !searchText.isEmpty {
                        Text("没有找到与「\(searchText)」相关的贴纸")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                        Text("换个关键词，或清空搜索看看全部")
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoToolTextSecondary)
                    } else if case .group(let name) = filter {
                        Text("「\(name)」分组还没有贴纸")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                        Text("直接拍照制作，或在「全部」里批量移入此分组")
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoToolTextSecondary)
                    } else {
                        Text("把身边的一件东西做成贴纸")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                        Text("耳机、水杯、书、跑鞋——拍下来就是你的")
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 网格与批量栏

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 10) {
                ForEach(assets.renderable, id: \.objectID) { asset in
                    cell(asset)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func cell(_ asset: VisualAsset) -> some View {
        let assetID = (asset.value(forKey: "id") as? UUID) ?? UUID()
        let isSelected = selectedIDs.contains(assetID)
        let descriptor = VisualDescriptor(assetID: assetID,
                                          winningRevisionID: assetID,
                                          kind: VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) ?? .sticker,
                                          presentation: asset.defaultPresentation)
        let isFav = (asset.value(forKey: "isFavorite") as? Bool) == true
        return Button {
            if isSelecting {
                if isSelected { selectedIDs.remove(assetID) }
                else { selectedIDs.insert(assetID) }
            } else {
                detailTarget = asset
            }
        } label: {
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
                if isSelecting && isSelected {
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
                if isSelecting {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.holoToolAction : Color.holoToolInset)
                            .frame(width: 20, height: 20)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.holoToolOnAction)
                        }
                    }
                    .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isSelecting {
                Button { renameTarget = asset; renameText = (asset.value(forKey: "displayName") as? String) ?? "" } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Menu {
                    Button { assignGroup(nil, to: [asset]) } label: {
                        Label("未分组", systemImage: asset.groupName == nil ? "checkmark" : "tray")
                    }
                    ForEach(groups, id: \.self) { group in
                        Button { assignGroup(group, to: [asset]) } label: {
                            Label(group, systemImage: asset.groupName == group ? "checkmark" : "folder")
                        }
                    }
                } label: {
                    Label("移至分组", systemImage: "folder")
                }
                Button { editAsset(asset) } label: {
                    Label("编辑贴纸", systemImage: "slider.horizontal.3")
                }
                Button { toggleFavorite(asset) } label: {
                    Label(isFav ? "取消收藏" : "收藏", systemImage: isFav ? "star.slash" : "star")
                }
                Button { exportPNG(asset) } label: {
                    Label("导出透明 PNG", systemImage: "square.and.arrow.up")
                }
                Button { remake(asset) } label: {
                    Label("重新制作一份", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Button(role: .destructive) { deleteTarget = asset } label: {
                    Label("彻底删除…", systemImage: "trash")
                }
            }
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    let targets = selectedAssets()
                    assignGroup(nil, to: targets)
                    exitSelectionMode()
                    showToast(String(localized: "已移出分组"))
                } label: {
                    Label(String(localized: "未分组"), systemImage: "tray")
                }
                if !groups.isEmpty {
                    Divider()
                    ForEach(groups, id: \.self) { group in
                        Button {
                            let targets = selectedAssets()
                            assignGroup(group, to: targets)
                            exitSelectionMode()
                            showToast(String(localized: "已移至「\(group)」"))
                        } label: {
                            Label(group, systemImage: "folder")
                        }
                    }
                }
                Divider()
                Button { showNewGroupAlert = true } label: {
                    Label(String(localized: "新建分组…"), systemImage: "plus")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(String(localized: "移至分组"))
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundColor(selectedIDs.isEmpty ? .holoToolTextSecondary : .holoToolText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.holoToolSurface)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.holoToolBorder, lineWidth: 0.8))
            }
            .disabled(selectedIDs.isEmpty)

            Button {
                showBatchDeleteConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text(String(localized: "删除 (\(selectedIDs.count))"))
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundColor(selectedIDs.isEmpty ? .holoToolTextSecondary : .holoToolOnAction)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(selectedIDs.isEmpty ? Color.holoToolSurface : Color.holoToolError)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - 操作

    private func exportPNG(_ asset: VisualAsset) {
        let style = asset.visualMetadata.resolvedBorderStyle ?? .adaptivePaper
        let weight = asset.visualMetadata.resolvedBorderWeight
        guard let image = StickerRenderer.renderExportImage(
            asset: asset, borderStyle: style, borderWeight: weight, displayScale: UIScreen.main.scale),
              let png = VisualAssetImageProcessor.encodePNG(image) else {
            showToast("这张素材暂时无法导出")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("贴纸-\(UUID().uuidString.prefix(6)).png")
        do {
            try png.write(to: url)
            exportShareItem = ExportShareItem(url: url)
        } catch {
            showToast("导出没有完成")
        }
    }

    private func hardDelete(_ asset: VisualAsset) {
        do {
            try VisualAssetManagement.hardDelete(asset: asset, in: context)
        } catch {
            showToast("删除没有完成，请重试")
        }
        deleteTarget = nil
        reload()
    }

    private func editAsset(_ asset: VisualAsset) {
        let subjectData = (asset.value(forKey: "contentData") as? Data)
            ?? (asset.value(forKey: "sourceData") as? Data)
        guard let subjectData, !subjectData.isEmpty else {
            showToast("这张素材没有可编辑的主体，请用「重新制作一份」")
            return
        }
        Task { await startConfirm(with: subjectData, editing: asset) }
    }

    // MARK: - 重命名子弹层

    private func renameSheet(_ asset: VisualAsset) -> some View {
        VStack(spacing: 12) {
            Text("重命名").font(.system(size: 16, weight: .semibold))
            TextField("贴纸名称", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { renameTarget = nil }
                Spacer()
                Button("完成") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    asset.setValue(trimmed.isEmpty ? nil : trimmed, forKey: "displayName")
                    asset.setValue(Date(), forKey: "metadataUpdatedAt")
                    try? context.save()
                    renameTarget = nil
                    reload()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoToolAction)
            }
        }
        .padding(18)
        .presentationDetents([.height(170)])
    }

    private func libraryButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.holoToolAction)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.holoToolSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.holoToolBorder, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 使用位置解析器（只查当前真正胜出记录，解析人类可读业务名，不露 UUID）

struct VisualAssetUsageRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
}

enum VisualAssetUsageResolver {
    static func resolveUsages(for asset: VisualAsset, in context: NSManagedObjectContext) -> [VisualAssetUsageRow] {
        guard let assetID = asset.value(forKey: "id") as? UUID else { return [] }
        let request = NSFetchRequest<VisualPlacementRevision>(entityName: "VisualPlacementRevision")
        request.sortDescriptors = [NSSortDescriptor(key: "changedAt", ascending: false)]
        guard let revisions = try? context.fetch(request) else { return [] }

        // 按 (ownerKind, ownerKey, slot) 去重，仅保留当前真正胜出且等于 assetID 的位置
        var visitedKeys = Set<String>()
        var rows: [VisualAssetUsageRow] = []

        for revision in revisions {
            let kind = revision.value(forKey: "ownerKind") as? String ?? ""
            let key = revision.value(forKey: "ownerKey") as? String ?? ""
            let slot = revision.value(forKey: "slot") as? String ?? ""
            let usageKey = "\(kind)|\(key)|\(slot)"
            guard !visitedKeys.contains(usageKey) else { continue }
            visitedKeys.insert(usageKey)

            let resolved = VisualAssetRepository.shared.resolvePlacement(
                ownerKind: kind, ownerKey: key, slot: slot, in: context)
            guard case .assetReady(let descriptor) = resolved, descriptor.assetID == assetID else {
                continue
            }

            if let row = describeUsage(usageKey: usageKey, kind: kind, key: key, in: context) {
                rows.append(row)
            }
        }
        return rows
    }

    private static func describeUsage(usageKey: String, kind: String, key: String,
                                      in context: NSManagedObjectContext) -> VisualAssetUsageRow? {
        switch kind {
        case HabitFolder.visualOwnerKind:
            if let uuid = UUID(uuidString: key),
               let folder = try? context.fetch(HabitFolder.fetchRequest(id: uuid)).first {
                return VisualAssetUsageRow(id: usageKey, title: folder.name,
                                           detail: String(localized: "习惯文件夹"), icon: "folder")
            }
            return VisualAssetUsageRow(id: usageKey, title: String(localized: "习惯文件夹"),
                                       detail: String(localized: "未同步到本地的文件夹"), icon: "folder")
        case SpendingProject.visualOwnerKind:
            if let uuid = UUID(uuidString: key) {
                let req = NSFetchRequest<SpendingProject>(entityName: "SpendingProject")
                req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                req.fetchLimit = 1
                if let project = try? context.fetch(req).first {
                    return VisualAssetUsageRow(id: usageKey, title: project.name,
                                               detail: String(localized: "固定支出项目"), icon: "creditcard")
                }
            }
            return VisualAssetUsageRow(id: usageKey, title: String(localized: "固定支出项目"),
                                       detail: String(localized: "未同步到本地的项目"), icon: "creditcard")
        case Thought.visualOwnerKind:
            if let uuid = UUID(uuidString: key) {
                let req = NSFetchRequest<Thought>(entityName: "Thought")
                req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                req.fetchLimit = 1
                if let thought = try? context.fetch(req).first {
                    let snippet = thought.content
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                    let title = snippet.isEmpty
                        ? String(localized: "图片想法")
                        : String(snippet.prefix(24))
                    return VisualAssetUsageRow(id: usageKey, title: title,
                                               detail: String(localized: "想法头图"), icon: "text.bubble")
                }
            }
            return VisualAssetUsageRow(id: usageKey, title: String(localized: "想法头图"),
                                       detail: String(localized: "未同步到本地的想法"), icon: "text.bubble")
        case "galleryDay":
            return VisualAssetUsageRow(id: usageKey, title: key.isEmpty ? String(localized: "记忆长廊") : key,
                                       detail: String(localized: "长廊日封面"), icon: "calendar")
        default:
            return VisualAssetUsageRow(id: usageKey, title: String(localized: "其他记录"),
                                       detail: String(localized: "正在使用"), icon: "square.on.square")
        }
    }
}

// MARK: - 贴纸详情 Sheet（单击卡片打开：高清预览 + 名称/分组 + 使用位置 + 操作）

private struct StickerAssetDetailSheet: View {
    let asset: VisualAsset
    let groups: [String]
    let usages: [VisualAssetUsageRow]
    let onToggleFavorite: () -> Void
    let onRename: (String) -> Void
    let onChangeGroup: (String?) -> Void
    let onCreateGroupAndAssign: (String) -> Void
    let onEdit: () -> Void
    let onRemake: () -> Void
    let onExport: () -> Void
    let onHide: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameText: String = ""
    @State private var isFavorite: Bool = false
    @State private var currentGroup: String?
    @State private var showNewGroupAlert = false
    @State private var newGroupText = ""

    var body: some View {
        let assetID = (asset.value(forKey: "id") as? UUID) ?? UUID()
        let descriptor = VisualDescriptor(
            assetID: assetID,
            winningRevisionID: assetID,
            kind: VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) ?? .sticker,
            presentation: asset.defaultPresentation)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 高清预览区
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.holoToolInset)
                        VisualAssetView(descriptor: descriptor, role: .hero)
                            .padding(18)
                    }
                    .frame(height: 220)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isFavorite.toggle()
                            onToggleFavorite()
                        } label: {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(isFavorite ? Color.holoStarTint : .holoToolTextSecondary)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }

                    // 名称 & 分组卡片
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text(String(localized: "名称"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                                .frame(width: 40, alignment: .leading)
                            TextField(String(localized: "输入贴纸名称"), text: $nameText)
                                .font(.system(size: 14))
                                .foregroundColor(.holoToolText)
                                .submitLabel(.done)
                                .onSubmit {
                                    onRename(nameText.trimmingCharacters(in: .whitespacesAndNewlines))
                                }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)

                        Divider().padding(.leading, 14)

                        HStack(spacing: 10) {
                            Text(String(localized: "分组"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                                .frame(width: 40, alignment: .leading)
                            Menu {
                                Button {
                                    currentGroup = nil
                                    onChangeGroup(nil)
                                } label: {
                                    Label(String(localized: "未分组"),
                                          systemImage: currentGroup == nil ? "checkmark" : "tray")
                                }
                                if !groups.isEmpty {
                                    Divider()
                                    ForEach(groups, id: \.self) { group in
                                        Button {
                                            currentGroup = group
                                            onChangeGroup(group)
                                        } label: {
                                            Label(group,
                                                  systemImage: currentGroup == group ? "checkmark" : "folder")
                                        }
                                    }
                                }
                                Divider()
                                Button { showNewGroupAlert = true } label: {
                                    Label(String(localized: "新建分组…"), systemImage: "plus")
                                }
                            } label: {
                                HStack {
                                    Text(currentGroup ?? String(localized: "未分组"))
                                        .font(.system(size: 14))
                                        .foregroundColor(currentGroup == nil ? .holoToolTextSecondary : .holoToolText)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11))
                                        .foregroundColor(.holoToolTextSecondary)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .background(Color.holoToolSurface)
                    .cornerRadius(14)

                    // 快捷操作行
                    HStack(spacing: 8) {
                        detailActionButton(icon: "slider.horizontal.3", title: String(localized: "编辑"), action: onEdit)
                        detailActionButton(icon: "arrow.triangle.2.circlepath", title: String(localized: "重做"), action: onRemake)
                        detailActionButton(icon: "square.and.arrow.up", title: String(localized: "导出 PNG"), action: onExport)
                    }

                    // 使用位置区块
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "正在使用 (\(usages.count))"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.holoToolTextSecondary)

                        if usages.isEmpty {
                            Text(String(localized: "本机还没有记录用到这张贴纸"))
                                .font(.system(size: 13))
                                .foregroundColor(.holoToolTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.holoToolSurface)
                                .cornerRadius(12)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(usages.enumerated()), id: \.element.id) { idx, usage in
                                    if idx > 0 { Divider().padding(.leading, 44) }
                                    HStack(spacing: 10) {
                                        Image(systemName: usage.icon)
                                            .font(.system(size: 14))
                                            .foregroundColor(.holoToolAction)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(usage.title)
                                                .font(.system(size: 13.5))
                                                .foregroundColor(.holoToolText)
                                                .lineLimit(1)
                                            Text(usage.detail)
                                                .font(.system(size: 11))
                                                .foregroundColor(.holoToolTextSecondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                }
                            }
                            .background(Color.holoToolSurface)
                            .cornerRadius(12)
                        }
                    }

                    // 危险操作区
                    HStack(spacing: 10) {
                        Button(action: onHide) {
                            Text(String(localized: "移出素材库"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.holoToolSurface)
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive, action: onDelete) {
                            Text(String(localized: "彻底删除"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.holoToolError)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color.holoToolSurface)
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .background(Color.holoToolBackground)
            .navigationTitle(String(localized: "贴纸详情"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) {
                        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let original = (asset.value(forKey: "displayName") as? String) ?? ""
                        if trimmed != original {
                            onRename(trimmed)
                        }
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }
            .alert(String(localized: "新建分组"), isPresented: $showNewGroupAlert) {
                TextField(String(localized: "分组名称"), text: $newGroupText)
                Button(String(localized: "取消"), role: .cancel) { newGroupText = "" }
                Button(String(localized: "创建并移入")) {
                    let trimmed = newGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        currentGroup = trimmed
                        onCreateGroupAndAssign(trimmed)
                    }
                    newGroupText = ""
                }
            }
            .onAppear {
                nameText = (asset.value(forKey: "displayName") as? String) ?? ""
                isFavorite = (asset.value(forKey: "isFavorite") as? Bool) == true
                currentGroup = asset.groupName
            }
        }
        .presentationDetents([.large])
    }

    private func detailActionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(.holoToolText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.holoToolSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.holoToolBorder, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}
