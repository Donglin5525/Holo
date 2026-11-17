//
//  VisualAssetLibraryView.swift
//  Holo
//
//  「我的贴纸」素材库（方案 01 §4，原型场景二 1:1）：
//  最近使用 / 全部 / 收藏三分栏；长按菜单（重命名/收藏/查看使用位置/重新制作/
//  导出透明 PNG/移出素材库/彻底删除）；底部三入口（拍照制作/从相册选/从文件导入）。
//  空态只说一句「把身边的一件东西做成贴纸」，不预生成内容；默认名「贴纸 1、贴纸 2…」。
//

import SwiftUI
import CoreData

struct VisualAssetLibraryView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable {
        case recent = "最近使用"
        case all = "全部"
        case favorite = "收藏"
    }

    @State private var tab: Tab = .recent
    @State private var assets: [VisualAsset] = []
    @State private var renameTarget: VisualAsset?
    @State private var renameText = ""
    @State private var deleteTarget: VisualAsset?
    @State private var showMaker = false
    @State private var toast: String?
    @State private var usageTarget: VisualAsset?

    var body: some View {
        HoloSheetScaffold(title: "我的贴纸",
                          onClose: { dismiss() },
                          primaryTitle: nil) {
            VStack(spacing: 10) {
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

                // 底部三入口（01 §3.1：与拍照同为一等公民）
                HStack(spacing: 8) {
                    libraryButton(icon: "camera", title: "拍照制作") { showMaker = true }
                    libraryButton(icon: "photo.on.rectangle", title: "从相册选") { showMaker = true }
                    libraryButton(icon: "doc", title: "从文件导入") { showMaker = true }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
            .padding(.top, 6)
        }
        .task { reload() }
        .onChange(of: tab) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .visualAssetsDidChange)) { _ in
            reload()
        }
        .sheet(isPresented: $showMaker) {
            StickerMakerView(pickerTitle: String(localized: "制作贴纸")) { _, _ in
                reload()
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $renameTarget) { asset in
            renameSheet(asset)
        }
        .sheet(item: $usageTarget) { asset in
            usageSheet(asset)
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
        assets = (try? context.fetch(request)) ?? []
    }

    // MARK: - 空态（不预生成任何内容）

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundColor(.holoToolTextSecondary)
            Text("把身边的一件东西做成贴纸")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoToolTextSecondary)
            Text("耳机、水杯、书、跑鞋——拍下来就是你的")
                .font(.system(size: 11.5))
                .foregroundColor(.holoToolTextSecondary)
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
        let descriptor = VisualDescriptor(assetID: (asset.value(forKey: "id") as? UUID) ?? UUID(),
                                          winningRevisionID: UUID(),
                                          kind: VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) ?? .sticker,
                                          presentation: nil)
        return Menu {
            Button { renameTarget = asset; renameText = (asset.value(forKey: "displayName") as? String) ?? "" } label: {
                Label("重命名", systemImage: "pencil")
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
            Button { showMaker = true } label: {
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
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let root = scenes.first?.keyWindow?.rootViewController
            root?.present(activity, animated: true)
            toast = nil
        } catch {
            toast = "导出没有完成"
        }
    }

    /// 二段删除第一段：墓碑 + 清 Binary（同事务）；远端收到墓碑后同样清理
    private func hardDelete(_ asset: VisualAsset) {
        guard let assetID = asset.value(forKey: "id") as? UUID else { return }
        context.performAndWait {
            do {
                _ = try VisualAssetRepository.shared.writeTombstone(operationID: UUID(), assetID: assetID, in: context)
                for key in ["sourceData", "maskData", "contentData", "thumbnailData"] {
                    asset.setValue(nil, forKey: key)
                }
                asset.setValue("recordOnly", forKey: "libraryVisibility")
                try context.save()
            } catch {
                toast = "删除没有完成，请重试"
            }
        }
        deleteTarget = nil
        reload()
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
            let title: String
            let icon: String
            switch kind {
            case "spendingProject": title = "固定支出项目"; icon = "creditcard"
            case "thought": title = "想法头图"; icon = "text.bubble"
            case "galleryDay": title = "长廊日封面"; icon = "calendar"
            default: title = kind.isEmpty ? "其他位置" : kind; icon = "square.on.square"
            }
            rows.append(UsageRow(ownerKey: "\(kind)|\(key)|\(slot)", title: title,
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
