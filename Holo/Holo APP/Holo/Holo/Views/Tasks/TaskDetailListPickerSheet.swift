//
//  TaskDetailListPickerSheet.swift
//  Holo
//
//  任务详情清单选择器 Sheet（新建/编辑/删除清单入口）——
//  2026-10-24 随真机主线程栈溢出排险从 TaskDetailView 拆出（纯搬移，界面/行为零变化）。
//

import SwiftUI

/// 删除目标类型（清单）
enum DeleteTarget: Identifiable {
    case list(TodoList)
    var id: String {
        switch self {
        case .list(let l): return "list-\(l.id)"
        }
    }
}

struct TaskDetailListPickerSheet: View {

    @ObservedObject var repository: TodoRepository
    @Binding var selectedListId: UUID?
    @Binding var showListPicker: Bool
    let onDeleteTarget: (DeleteTarget) -> Void

    @State private var showAddListSheet = false
    @State private var showEditListSheet = false
    @State private var editingList: TodoList? = nil
    @State private var showDeleteConfirm = false
    @State private var itemToDelete: DeleteTarget? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.md) {
                        Button {
                            showAddListSheet = true
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoPrimary)

                                Text("新建清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoPrimary)

                                Spacer()
                            }
                            .padding(.horizontal, HoloSpacing.lg)
                            .padding(.vertical, HoloSpacing.md)
                            .background(Color.holoPrimary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(.plain)

                        Button {
                            selectedListId = nil
                            showListPicker = false
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "tray")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)

                                Text("收件箱（未归类）")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                if selectedListId == nil {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.holoPrimary)
                                }
                            }
                            .padding(.horizontal, HoloSpacing.lg)
                            .padding(.vertical, HoloSpacing.md)
                            .background(selectedListId == nil ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                        }
                        .buttonStyle(.plain)

                        ForEach(allLists, id: \.id) { list in
                            Button {
                                selectedListId = list.id
                                showListPicker = false
                            } label: {
                                HStack(spacing: HoloSpacing.sm) {
                                    Circle()
                                        .fill(Color(hex: list.color ?? "#007AFF"))
                                        .frame(width: 10, height: 10)

                                    Text(list.name)
                                        .font(.holoBody)
                                        .foregroundColor(.holoTextPrimary)

                                    Spacer()

                                    if selectedListId == list.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.holoPrimary)
                                    }
                                }
                                .padding(.horizontal, HoloSpacing.lg)
                                .padding(.vertical, HoloSpacing.md)
                                .background(selectedListId == list.id ? Color(hex: list.color ?? "#007AFF").opacity(0.1) : Color.holoCardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    editingList = list
                                    showEditListSheet = true
                                } label: {
                                    Label("编辑清单", systemImage: "pencil")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    itemToDelete = .list(list)
                                    showDeleteConfirm = true
                                } label: {
                                    Label("删除清单", systemImage: "trash")
                                }
                            }
                        }

                        if allLists.isEmpty {
                            VStack(spacing: HoloSpacing.md) {
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                                Text("暂无清单")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextSecondary)

                                Text("点击上方\"新建清单\"创建")
                                    .font(.holoCaption)
                                    .foregroundColor(.holoTextSecondary.opacity(0.7))
                            }
                            .padding(.top, HoloSpacing.xl)
                        }
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("选择清单")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.navTrailing) {
                    Button("完成") {
                        showListPicker = false
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .sheet(isPresented: $showAddListSheet) {
                AddListSheet(repository: repository, folder: nil)
            }
            .sheet(isPresented: $showEditListSheet) {
                if let list = editingList {
                    EditListSheet(repository: repository, list: list, folders: repository.folders)
                }
            }
            .alert("确认删除", isPresented: $showDeleteConfirm, presenting: itemToDelete) { target in
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    onDeleteTarget(target)
                }
            } message: { target in
                switch target {
                case .list(let list):
                    Text("确定要删除清单「\(list.name)」吗？该清单下的所有任务都将被删除。")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 所有清单（包括没有文件夹的）
    private var allLists: [TodoList] {
        repository.allActiveLists()
    }
}
