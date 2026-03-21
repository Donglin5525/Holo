//
//  ArchiveManagementView.swift
//  Holo
//
//  归档管理页面
//  查看和管理已归档的标签与清单
//

import SwiftUI

// MARK: - Archive Tab

/// 归档类型标签页
enum ArchiveTab: String, CaseIterable {
    case tags = "标签"
    case lists = "清单"

    var icon: String {
        switch self {
        case .tags: return "tag"
        case .lists: return "list.bullet.rectangle"
        }
    }
}

// MARK: - ArchiveManagementView

/// 归档管理页面
struct ArchiveManagementView: View {

    // MARK: - Properties

    @ObservedObject var repository: TodoRepository
    @Environment(\.dismiss) private var dismiss

    /// 当前选中的标签页
    @State private var selectedTab: ArchiveTab = .tags

    /// 已归档标签
    @State private var archivedTags: [TodoTag] = []
    /// 已归档清单
    @State private var archivedLists: [TodoList] = []

    /// 删除确认对话框
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: DeleteTarget? = nil

    /// 删除目标类型
    private enum DeleteTarget: Identifiable {
        case tag(TodoTag)
        case list(TodoList)

        var id: UUID {
            switch self {
            case .tag(let tag): return tag.id
            case .list(let list): return list.id
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            tabSelectorView

            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .tags:
                        tagsContentView
                    case .lists:
                        listsContentView
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
        }
        .background(Color.holoBackground)
        .onAppear {
            loadArchivedData()
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {
                itemToDelete = nil
            }
            Button("删除", role: .destructive) {
                performDelete()
            }
        } message: {
            Text("此操作不可撤销，确定要永久删除吗？")
        }
    }

    // MARK: - 数据加载

    private func loadArchivedData() {
        archivedTags = repository.loadArchivedTags()
        archivedLists = repository.loadArchivedLists()
    }

    // MARK: - 顶部导航栏

    private var headerView: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Text("归档管理")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 占位，保持标题居中
            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 标签页选择器

    private var tabSelectorView: some View {
        HStack(spacing: 0) {
            ForEach(ArchiveTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 8) {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.holoCaption)
                            .foregroundColor(selectedTab == tab ? .holoPrimary : .holoTextSecondary)

                        Rectangle()
                            .fill(selectedTab == tab ? Color.holoPrimary : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.sm)
        .background(Color.holoBackground)
    }

    // MARK: - 标签内容视图

    private var tagsContentView: some View {
        VStack(spacing: 16) {
            // 统计信息
            statsHeaderView(
                activeCount: repository.tags.count,
                archivedCount: archivedTags.count,
                type: "标签"
            )

            if archivedTags.isEmpty {
                emptyStateView(message: "暂无已归档的标签")
            } else {
                ForEach(archivedTags, id: \.id) { tag in
                    ArchivedTagRow(
                        tag: tag,
                        onRestore: { restoreTag(tag) },
                        onDelete: {
                            itemToDelete = .tag(tag)
                            showDeleteConfirmation = true
                        }
                    )
                }
            }
        }
    }

    // MARK: - 清单内容视图

    private var listsContentView: some View {
        VStack(spacing: 16) {
            // 统计信息
            let activeListsCount = repository.folders.reduce(into: 0) { $0 += $1.listsArray.filter { !$0.archived }.count }
            statsHeaderView(
                activeCount: activeListsCount,
                archivedCount: archivedLists.count,
                type: "清单"
            )

            if archivedLists.isEmpty {
                emptyStateView(message: "暂无已归档的清单")
            } else {
                ForEach(archivedLists, id: \.id) { list in
                    ArchivedListRow(
                        list: list,
                        onRestore: { restoreList(list) },
                        onDelete: {
                            itemToDelete = .list(list)
                            showDeleteConfirmation = true
                        }
                    )
                }
            }
        }
    }

    // MARK: - 统计信息头部

    private func statsHeaderView(activeCount: Int, archivedCount: Int, type: String) -> some View {
        HStack {
            Text("活跃\(type)")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Text("\(activeCount)")
                .font(.holoBody)
                .bold()
                .foregroundColor(.holoPrimary)

            Spacer()

            Text("已归档")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Text("\(archivedCount)")
                .font(.holoBody)
                .bold()
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.horizontal, HoloSpacing.sm)
    }

    // MARK: - 空状态视图

    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))

            Text(message)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.top, 60)
    }

    // MARK: - 操作方法

    private func restoreTag(_ tag: TodoTag) {
        do {
            try repository.restoreTag(tag)
            loadArchivedData()
        } catch {
            print("[ArchiveManagementView] 恢复标签失败: \(error)")
        }
    }

    private func restoreList(_ list: TodoList) {
        do {
            try repository.unarchiveList(list)
            loadArchivedData()
        } catch {
            print("[ArchiveManagementView] 恢复清单失败: \(error)")
        }
    }

    private func performDelete() {
        guard let target = itemToDelete else { return }

        do {
            switch target {
            case .tag(let tag):
                try repository.permanentlyDeleteTag(tag)
            case .list(let list):
                try repository.deleteList(list)
            }
            loadArchivedData()
        } catch {
            print("[ArchiveManagementView] 删除失败: \(error)")
        }

        itemToDelete = nil
    }
}

// MARK: - Archived Tag Row

/// 已归档标签行视图
private struct ArchivedTagRow: View {
    let tag: TodoTag
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 颜色指示器
            Circle()
                .fill(Color(hex: tag.color) ?? .holoPrimary)
                .frame(width: 12, height: 12)

            // 标签名称
            Text(tag.name)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            // 操作按钮
            HStack(spacing: 8) {
                Button(action: onRestore) {
                    Text("恢复")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.holoPrimary.opacity(0.1))
                        .clipShape(Capsule())
                }

                Button(action: onDelete) {
                    Text("删除")
                        .font(.holoCaption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }
}

// MARK: - Archived List Row

/// 已归档清单行视图
private struct ArchivedListRow: View {
    let list: TodoList
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 颜色指示器
            Circle()
                .fill(list.color.flatMap { Color(hex: $0) } ?? .holoPrimary)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                // 清单名称
                Text(list.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                // 所属文件夹
                if let folder = list.folder {
                    Text(folder.name)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }

            Spacer()

            // 操作按钮
            HStack(spacing: 8) {
                Button(action: onRestore) {
                    Text("恢复")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.holoPrimary.opacity(0.1))
                        .clipShape(Capsule())
                }

                Button(action: onDelete) {
                    Text("删除")
                        .font(.holoCaption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }
}

// MARK: - Preview

#Preview {
    ArchiveManagementView(repository: TodoRepository.shared)
}
