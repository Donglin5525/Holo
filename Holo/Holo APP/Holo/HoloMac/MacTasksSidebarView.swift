//
//  MacTasksSidebarView.swift
//  HoloMac
//
//  任务侧栏：智能范围行（今天/已过期/全部/收件箱）+ 清单区 + 已完成。
//
//  macOS 红线：List(selection:) 的 tag 必须挂在 ForEach/条件直出的行视图顶层；
//  文件夹是灰色标签行（无 tag 天然不可选），其下清单行用 leading padding 表达层级。
//  清单管理（新建/重命名/改色/归档/删除）全部走 TodoRepository 既有 CRUD。
//

import SwiftUI
import os

struct MacTasksSidebarView: View {

    @ObservedObject var model: MacTasksBrowserModel

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacTasksSidebar")

    /// 新建清单弹层
    @State private var showNewList = false
    /// 重命名/改色清单（同一表单承载）
    @State private var renameTarget: TodoList?
    /// 删除清单确认
    @State private var deleteListTarget: TodoList?

    /// 12 色板（与 iOS 清单颜色选项同源图表色）
    private static let listPalette: [String] = [
        "#FF9500", "#FF3B30", "#FF2D55", "#AF52DE", "#5856D6", "#007AFF",
        "#34C759", "#00C7BE", "#30B0C7", "#FFCC00", "#A2845E", "#8E8E93",
    ]

    private var scopeSelection: Binding<MacTaskBrowseScope?> {
        Binding(
            get: { model.scope },
            set: { model.scope = $0 ?? .today })
    }

    var body: some View {
        List(selection: scopeSelection) {
                Section(String(localized: "任务")) {
                    presetRow(.today)
                    presetRow(.overdue)
                    presetRow(.all)
                    presetRow(.inbox)
                    presetRow(.quadrant)
                }

                Section {
                    // 清单区头：标题 + 新建按钮
                    HStack {
                        Text(String(localized: "清单"))
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoToolTextSecondary)
                        Spacer()
                        Button {
                            showNewList = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.holoToolTextSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "新建清单"))
                        .accessibilityIdentifier("mac.task.newListButton")
                    }

                    // 平铺清单（不属于任何文件夹）
                    ForEach(model.lists, id: \.id) { list in
                        listRow(list)
                    }

                    // 文件夹 = 灰色标签行（不可选）+ 其下清单行缩进
                    ForEach(model.folders, id: \.id) { folder in
                        folderLabelRow(folder)
                        ForEach(folderSortedLists(folder), id: \.id) { list in
                            listRow(list, indented: true)
                        }
                    }

                    if model.lists.isEmpty && model.folders.isEmpty {
                        Text(String(localized: "点右上角 + 新建第一个清单"))
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoToolTextSecondary.opacity(0.6))
                    }
                }

                Section {
                    presetRow(.completed)
                }
            }
            .listStyle(.sidebar)
            // 模块切换区悬浮在列表顶部（safeAreaInset，不用 VStack 包裹——
            // 包裹改变 List 视图身份，实测触发启动期 StateObject 崩溃）
            .safeAreaInset(edge: .top, spacing: 0) {
                MacModuleSwitcher()
                    .background(Color.holoToolBackground.opacity(0.9))
            }
        .sheet(isPresented: $showNewList) {
            MacListEditSheet(
                title: String(localized: "新建清单"),
                initialName: "",
                initialColor: Self.listPalette.first ?? "#FF9500",
                palette: Self.listPalette,
                confirmTitle: String(localized: "创建"))
            { name, color in
                do {
                    _ = try model.repository.createList(name: name, color: color)
                } catch {
                    Self.logger.error("新建清单失败: \(error.localizedDescription)")
                }
                model.reloadNow()
            }
        }
        .sheet(isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            if let list = renameTarget {
                MacListEditSheet(
                    title: String(localized: "重命名清单"),
                    initialName: list.name ?? "",
                    initialColor: list.color ?? Self.listPalette.first ?? "#FF9500",
                    palette: Self.listPalette,
                    confirmTitle: String(localized: "保存"))
                { name, color in
                    try? model.repository.updateList(list, name: name, color: color)
                    model.reloadNow()
                }
            }
        }
        .confirmationDialog(
            String(localized: "删除清单「\(renameTargetNameForDelete)」？"),
            isPresented: Binding(
                get: { deleteListTarget != nil },
                set: { if !$0 { deleteListTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "删除"), role: .destructive) {
                if let list = deleteListTarget {
                    try? model.repository.deleteList(list)
                    // 删除的清单正是当前范围 → 回退到「今天」
                    if case .list(let id) = model.scope, id == list.id {
                        model.scope = .today
                    }
                    deleteListTarget = nil
                    model.reloadNow()
                }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "清单内的任务会一并删除并进入回收站，保留 30 天。"))
        }
    }

    private var renameTargetNameForDelete: String {
        deleteListTarget?.name ?? ""
    }

    // MARK: - 行视图

    private func presetRow(_ scope: MacTaskBrowseScope) -> some View {
        HStack(spacing: 8) {
            Image(systemName: scope.icon)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundColor(
                    scope == .overdue && (model.scopeCounts["overdue"] ?? 0) > 0
                        ? Color.holoError : Color.holoToolTextSecondary)
            Text(scope.presetTitle)
                .font(.system(size: 13))
            Spacer()
            Text("\(model.count(for: scope))")
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)
        }
        .tag(scope)
    }

    private func folderLabelRow(_ folder: TodoFolder) -> some View {
        Text(folder.name ?? "")
            .font(.holoTinyLabel)
            .foregroundColor(.holoToolTextSecondary.opacity(0.6))
            .padding(.leading, 4)
    }

    private func folderSortedLists(_ folder: TodoFolder) -> [TodoList] {
        let lists = folder.lists?.allObjects as? [TodoList] ?? []
        return lists.filter { !$0.archived }.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func listRow(_ list: TodoList, indented: Bool = false) -> some View {
        HStack(spacing: 8) {
            if indented {
                Color.clear.frame(width: 14)
            }
            Circle()
                .fill(Color(hex: list.color ?? "#007AFF"))
                .frame(width: 10, height: 10)
            Text(list.name ?? "")
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            Text("\(model.count(for: .list(list.id)))")
                .font(.holoTinyLabel)
                .foregroundColor(.holoToolTextSecondary)
        }
        .tag(MacTaskBrowseScope.list(list.id))
        .contextMenu {
            Button(String(localized: "重命名")) {
                renameTarget = list
            }
            Button(String(localized: "更改颜色")) {
                renameTarget = list  // 复用编辑 sheet（颜色在同一表单里改）
            }
            Divider()
            Button(String(localized: "删除清单"), role: .destructive) {
                deleteListTarget = list
            }
        }
    }
}

// MARK: - 范围标题（侧栏短标题，区别于中栏长标题）

extension MacTaskBrowseScope {
    var presetTitle: String {
        switch self {
        case .today: return String(localized: "今天")
        case .overdue: return String(localized: "已过期")
        case .all: return String(localized: "全部")
        case .inbox: return String(localized: "收件箱")
        case .quadrant: return String(localized: "四象限")
        case .completed: return String(localized: "已完成")
        case .list: return String(localized: "清单")
        }
    }
}

// MARK: - 清单新建/编辑弹层（三区骨架）

struct MacListEditSheet: View {

    let title: String
    let initialName: String
    let initialColor: String
    let palette: [String]
    let confirmTitle: String
    let onConfirm: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var color: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(HoloSpacing.lg)

            Divider()

            // 表单区
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(String(localized: "名称"))
                        .font(.holoLabel)
                        .foregroundColor(.holoToolTextSecondary)
                    TextField(String(localized: "清单名称"), text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(String(localized: "颜色"))
                        .font(.holoLabel)
                        .foregroundColor(.holoToolTextSecondary)
                    HStack(spacing: 8) {
                        ForEach(palette, id: \.self) { hex in
                            Button {
                                color = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Circle().strokeBorder(
                                            color == hex ? Color.holoToolText : Color.clear,
                                            lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(HoloSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Divider()

            // 底部按钮区（主按钮贴底右下；sheet 左上关闭走 .cancellationAction）
            HStack {
                Spacer()
                Button(String(localized: "取消"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    onConfirm(name.trimmingCharacters(in: .whitespacesAndNewlines), color)
                    dismiss()
                } label: {
                    Text(confirmTitle)
                        .padding(.horizontal, 6)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(HoloSpacing.lg)
        }
        .frame(minWidth: 380, minHeight: 280)
        .onAppear {
            name = initialName
            color = initialColor
        }
    }
}
