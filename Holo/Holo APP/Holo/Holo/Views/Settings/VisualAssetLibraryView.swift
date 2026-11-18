//
//  VisualAssetLibraryView.swift
//  Holo
//
//  「我的贴纸」素材库（方案 01 §4；2026-11-18 拆套娃重构 · 方案模块四）：
//  最近使用 / 全部 / 收藏三分栏；长按菜单（重命名/收藏/查看使用位置/重新制作/
//  导出透明 PNG/移出素材库/彻底删除）。
//  - 底部三入口直拉对应系统选择器（相机/相册/文件），拿到图直接栈内 push 确认页——
//    不再弹出重复的选择器首屏（拍板第 3 点：彻底消灭套娃）
//  - 长按「重新制作一份」载入该素材原图，进确认页重做后另存
//  - 导出走 SwiftUI .sheet 包装 UIActivityViewController（rootViewController.present
//    在 sheet 上会静默失败，B9）
//  - 空态只说一句「把身边的一件东西做成贴纸」，不预生成内容；默认名「贴纸 1、贴纸 2…」
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

    @State private var tab: Tab = .recent
    @State private var assets: [VisualAsset] = []
    /// 搜索词（按贴纸名过滤；11-19 需求 3）
    @State private var searchText = ""
    @State private var renameTarget: VisualAsset?
    @State private var renameText = ""
    @State private var deleteTarget: VisualAsset?
    @State private var toast: String?
    @State private var usageTarget: VisualAsset?
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
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolTextSecondary)
                    TextField(String(localized: "搜索贴纸名称"), text: $searchText)
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
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.holoToolSurface)
                .cornerRadius(11)
                .padding(.horizontal)
                Picker("分栏", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if assets.isEmpty {
                    emptyState
                } else {
                    grid
                }

                // 底部三入口：直拉对应系统选择器（01 §3.1：与拍照同为一等公民）
                HStack(spacing: 8) {
                    libraryButton(icon: "camera", title: "拍照制作") { launchCamera() }
                    libraryButton(icon: "photo.on.rectangle", title: "从相册选") {
                        launchPhotoLibrary()
                    }
                    libraryButton(icon: "doc", title: "从文件导入") {
                        activeMediaSource = .document
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
            .padding(.top, 6)
            .background(Color.holoToolBackground)
            .navigationTitle("我的贴纸")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
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
            .navigationDestination(isPresented: Binding(
                get: { confirmModel != nil },
                set: { if !$0 { confirmModel = nil } }
            )) {
                if let confirmModel {
                    StickerConfirmEditorView(model: confirmModel,
                                             useTitle: String(localized: "保存到我的贴纸"),
                                             supportsPhotoMode: false) { _, _ in
                        self.confirmModel = nil
                        reload()
                    }
                }
            }
        }
        .visualMediaPresenter(activeSource: $activeMediaSource) { data in
            await startConfirm(with: data)
        }
        .alert(String(localized: "无法访问相机"),
               isPresented: $cameraDenied) {
            Button(String(localized: "去设置")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "请在系统设置里允许 Holo 使用相机，或改用相册/文件导入"))
        }
        .task { reload() }
        .onChange(of: tab) { _ in reload() }
        .onChange(of: searchText) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
            reload()
        }
        .sheet(item: $renameTarget) { asset in
            renameSheet(asset)
        }
        .sheet(item: $usageTarget) { asset in
            usageSheet(asset)
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
        confirmModel = model
        if let asset {
            // 编辑模式（正确语义）：载入已抠好的主体+遮罩，保留修过的形状；
            // 原图字节留给 commit 回写（「重新制作一份」仍走原图）
            let subjectData = (asset.value(forKey: "contentData") as? Data) ?? data
            let loaded = model.loadEdited(subjectData: subjectData,
                                          maskData: asset.value(forKey: "maskData") as? Data)
            if loaded {
                model.editTargetAssetID = asset.value(forKey: "id") as? UUID
                model.name = (asset.value(forKey: "displayName") as? String) ?? ""
                if let source = asset.value(forKey: "sourceData") as? Data {
                    model.preservedSource = (source, (asset.value(forKey: "sourceUTType") as? String) ?? UTType.png.identifier)
                }
            } else {
                await model.ingestSmart(data: data)
            }
        } else {
            await model.ingestSmart(data: data)
        }
    }

    /// 长按「重新制作一份」：载入原图重做（无原图如实提示）
    private func remake(_ asset: VisualAsset) {
        guard let sourceData = asset.value(forKey: "sourceData") as? Data else {
            toast = "这张素材没有可重做的原图"
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

    /// 相册入口：读取权限一次性前置（iCloud 原图渐进下载的前提，想法模块同款）
    private func launchPhotoLibrary() {
        Task {
            await PhotoLibraryImageLoader.requestLibraryAccessIfNeeded()
            activeMediaSource = .photoLibrary
        }
    }

    // MARK: - 数据

    private func reload() {
        let request = NSFetchRequest<VisualAsset>(entityName: "VisualAsset")
        request.predicate = NSPredicate(format: "libraryVisibility == %@", "visible")
        switch tab {
        case .recent:
            request.sortDescriptors = [NSSortDescriptor(key: "metadataUpdatedAt", ascending: false)]
            request.fetchLimit = 30
        case .all:
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        case .favorite:
            request.predicate = NSPredicate(format: "libraryVisibility == %@ AND isFavorite == YES", "visible")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        }
        let fetched = (try? context.fetch(request)) ?? []
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty {
            assets = fetched
        } else {
            assets = fetched.filter { name in
                (name.value(forKey: "displayName") as? String)?
                    .localizedCaseInsensitiveContains(keyword) == true
            }
        }
    }

    // MARK: - 空态（不预生成任何内容；搜索无结果与空库分开说）

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "sparkles" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.holoToolTextSecondary)
            if searchText.isEmpty {
                Text("把身边的一件东西做成贴纸")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                Text("耳机、水杯、书、跑鞋——拍下来就是你的")
                    .font(.system(size: 11.5))
                    .foregroundColor(.holoToolTextSecondary)
            } else {
                Text("没有找到与「\(searchText)」相关的贴纸")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoToolTextSecondary)
                Text("换个关键词，或清空搜索看看全部")
                    .font(.system(size: 11.5))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 网格

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 10) {
                ForEach(assets.renderable, id: \.objectID) { asset in
                    cell(asset)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func cell(_ asset: VisualAsset) -> some View {
        // winningRevisionID 用稳定 assetID（不每次 body 生成新 UUID 触发无谓 diff）
        let assetID = (asset.value(forKey: "id") as? UUID) ?? UUID()
        let descriptor = VisualDescriptor(assetID: assetID,
                                          winningRevisionID: assetID,
                                          kind: VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) ?? .sticker,
                                          presentation: nil)
        return Menu {
            Button { renameTarget = asset; renameText = (asset.value(forKey: "displayName") as? String) ?? "" } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { editAsset(asset) } label: {
                Label("编辑贴纸", systemImage: "slider.horizontal.3")
            }
            Button {
                asset.setValue(!(asset.value(forKey: "isFavorite") as? Bool ?? false), forKey: "isFavorite")
                asset.setValue(Date(), forKey: "metadataUpdatedAt")
                try? context.save()
                reload()
            } label: {
                Label(asset.value(forKey: "isFavorite") as? Bool == true ? "取消收藏" : "收藏",
                      systemImage: "star")
            }
            Button { usageTarget = asset } label: {
                Label("查看使用位置", systemImage: "location")
            }
            Button { exportPNG(asset) } label: {
                Label("导出透明 PNG", systemImage: "square.and.arrow.up")
            }
            Button { remake(asset) } label: {
                Label("重新制作一份", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                asset.setValue("hidden", forKey: "libraryVisibility")
                try? context.save()
                reload()
            } label: {
                Label("移出素材库", systemImage: "eye.slash")
            }
            Button(role: .destructive) { deleteTarget = asset } label: {
                Label("彻底删除…", systemImage: "trash")
            }
        } label: {
            VStack(spacing: 4) {
                VisualAssetView(descriptor: descriptor, role: .icon)
                    .frame(height: 84)
                Text(defaultName(asset))
                    .font(.system(size: 9.5))
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(Color.holoToolSurface)
            .cornerRadius(14)
            .overlay(alignment: .topTrailing) {
                if asset.value(forKey: "isFavorite") as? Bool == true {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color.holoStarTint)
                        .padding(5)
                }
            }
        }
    }

    /// 命名可跳过：默认「贴纸 1、贴纸 2…」（按创建序）
    private func defaultName(_ asset: VisualAsset) -> String {
        let name = asset.value(forKey: "displayName") as? String
        if let name, !name.isEmpty { return name }
        if let created = asset.value(forKey: "createdAt") as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMdd"
            return "贴纸 \(formatter.string(from: created))"
        }
        return "贴纸"
    }

    // MARK: - 操作

    private func exportPNG(_ asset: VisualAsset) {
        guard let image = StickerRenderer.renderExportImage(
            asset: asset, borderStyle: .adaptivePaper, displayScale: UIScreen.main.scale),
              let png = VisualAssetImageProcessor.encodePNG(image) else {
            toast = "这张素材暂时无法导出"
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("贴纸-\(UUID().uuidString.prefix(6)).png")
        do {
            try png.write(to: url)
            // SwiftUI sheet 包装分享：rootViewController.present 在 sheet 上会静默失败（B9）
            exportShareItem = ExportShareItem(url: url)
        } catch {
            toast = "导出没有完成"
        }
    }

    /// 二段删除第一段：走共享管理通道（墓碑+清缓存+广播）
    private func hardDelete(_ asset: VisualAsset) {
        do {
            try VisualAssetManagement.hardDelete(asset: asset, in: context)
        } catch {
            toast = "删除没有完成，请重试"
        }
        deleteTarget = nil
        reload()
    }

    /// 编辑贴纸：载入已抠好的主体原地更新（原图只留给「重新制作一份」）
    private func editAsset(_ asset: VisualAsset) {
        let subjectData = (asset.value(forKey: "contentData") as? Data)
            ?? (asset.value(forKey: "sourceData") as? Data)
        guard let subjectData, !subjectData.isEmpty else {
            toast = "这张素材没有可编辑的主体，请用「重新制作一份」"
            return
        }
        Task { await startConfirm(with: subjectData, editing: asset) }
    }

    // MARK: - 子弹层

    private func renameSheet(_ asset: VisualAsset) -> some View {
        VStack(spacing: 12) {
            Text("重命名").font(.system(size: 16, weight: .semibold))
            TextField("贴纸名称", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("取消") { renameTarget = nil }
                Button("完成") {
                    asset.setValue(renameText.isEmpty ? nil : renameText, forKey: "displayName")
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
        .presentationDetents([.height(180)])
    }

    /// 查看使用位置：本机已同步到的记录；未知/未到达记录不伪造名称（01 §4）
    private func usageSheet(_ asset: VisualAsset) -> some View {
        let assetID = (asset.value(forKey: "id") as? UUID) ?? UUID()
        return Group {
            if let usages = fetchUsages(assetID: assetID), !usages.isEmpty {
                List(usages, id: \.ownerKey) { usage in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(usage.title)
                                .font(.system(size: 13.5))
                            Text(usage.detail)
                                .font(.system(size: 11))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                    } icon: {
                        Image(systemName: usage.icon)
                            .foregroundColor(.holoToolAction)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 24))
                        .foregroundColor(.holoToolTextSecondary)
                    Text("本机还没有记录用到这张贴纸")
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private struct UsageRow {
        let ownerKey: String
        let title: String
        let detail: String
        let icon: String
    }

    private func fetchUsages(assetID: UUID) -> [UsageRow]? {
        let request = NSFetchRequest<VisualPlacementRevision>(entityName: "VisualPlacementRevision")
        request.sortDescriptors = [NSSortDescriptor(key: "changedAt", ascending: false)]
        guard let revisions = try? context.fetch(request) else { return nil }
        var rows: [UsageRow] = []
        for revision in revisions {
            guard let json = revision.value(forKey: "payloadJSON") as? String,
                  let payload = try? VisualPlacementCoding.decode(from: json),
                  payload.action == .set, payload.selection?.assetID == assetID else { continue }
            let kind = revision.value(forKey: "ownerKind") as? String ?? ""
            let key = revision.value(forKey: "ownerKey") as? String ?? ""
            let slot = revision.value(forKey: "slot") as? String ?? ""
            let usageKey = "\(kind)|\(key)|\(slot)"
            if kind == HabitFolder.visualOwnerKind {
                guard slot == HabitFolder.visualSlot, let folderID = UUID(uuidString: key),
                      let folder = try? context.fetch(HabitFolder.fetchRequest(id: folderID)).first,
                      case .assetReady(let descriptor) = HabitFolder.resolveSticker(id: folderID, in: context),
                      descriptor.assetID == assetID,
                      !rows.contains(where: { $0.ownerKey == usageKey }) else { continue }
                rows.append(UsageRow(ownerKey: usageKey, title: folder.name,
                                     detail: String(localized: "习惯文件夹"), icon: "folder"))
                continue
            }
            let title: String
            let icon: String
            switch kind {
            case "spendingProject": title = "固定支出项目"; icon = "creditcard"
            case "thought": title = "想法头图"; icon = "text.bubble"
            case "galleryDay": title = "长廊日封面"; icon = "calendar"
            default: title = kind.isEmpty ? "其他位置" : kind; icon = "square.on.square"
            }
            rows.append(UsageRow(ownerKey: usageKey, title: title,
                                 detail: key.isEmpty ? slot : key, icon: icon))
        }
        return rows
    }

    private func libraryButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.holoToolSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.holoToolBorder, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}
