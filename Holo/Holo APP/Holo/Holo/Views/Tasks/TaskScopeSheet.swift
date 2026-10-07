//
//  TaskScopeSheet.swift
//  Holo
//
//  首页范围菜单（方案 §4.2）：全部未完成（默认）/今天到期/逾期/收件箱/指定清单/
//  已完成/归档；清单管理在菜单末尾；归档菜单与更多都可进入。
//

import SwiftUI

struct TaskScopeSheet: View {

    @ObservedObject var repository: TodoRepository
    @Binding var scope: TaskExperienceScope
    /// 各范围数量提示（四象限范围 = 活动未完成数）
    let scopeCounts: [TaskExperienceScope: Int]

    @Environment(\.dismiss) private var dismiss
    @State private var showArchiveManagement = false
    @State private var showNewListAlert = false
    @State private var newListName = ""
    @State private var newListError: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    scopeRow(.allUncompleted)
                    scopeRow(.todayDue)
                    scopeRow(.overdue)
                    scopeRow(.inbox)
                }
                Section(String(localized: "清单")) {
                    ForEach(repository.allActiveLists(), id: \.id) { list in
                        Button {
                            scope = .list(list.id)
                            dismiss()
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: list.color ?? "#007AFF"))
                                    .frame(width: 8, height: 8)
                                Text(list.name)
                                    .foregroundColor(.holoTextPrimary)
                                Spacer()
                                if case .list(let id) = scope, id == list.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.holoPrimary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section(String(localized: "历史")) {
                    scopeRow(.completed)
                    scopeRow(.archived)
                    Button {
                        showArchiveManagement = true
                    } label: {
                        Label(String(localized: "归档管理"), systemImage: "archivebox")
                            .foregroundColor(.holoTextPrimary)
                    }
                }
                Section {
                    Button {
                        showNewListAlert = true
                    } label: {
                        Label(String(localized: "新建清单"), systemImage: "plus.folder")
                            .foregroundColor(.holoTextPrimary)
                    }
                }
            }
            .navigationTitle(String(localized: "查看范围"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
            .sheet(isPresented: $showArchiveManagement) {
                ArchiveManagementView(repository: repository)
            }
            .alert(String(localized: "新建清单"), isPresented: $showNewListAlert) {
                TextField(String(localized: "清单名称"), text: $newListName)
                Button(String(localized: "创建")) {
                    let trimmed = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    do {
                        let list = try repository.createList(name: trimmed)
                        scope = .list(list.id)
                        dismiss()
                    } catch {
                        newListError = String(localized: "创建失败，请重试")
                    }
                    newListName = ""
                }
                Button(String(localized: "取消"), role: .cancel) { newListName = "" }
            } message: {
                Text(newListError ?? String(localized: "创建后会自动切换到该清单"))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func scopeRow(_ value: TaskExperienceScope) -> some View {
        Button {
            scope = value
            dismiss()
        } label: {
            HStack {
                Text(value.title)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                if let count = scopeCounts[value] {
                    Text("\(count)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                if scope == value {
                    Image(systemName: "checkmark")
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
