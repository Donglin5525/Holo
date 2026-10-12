//
//  EditListSheet.swift
//  Holo
//
//  编辑清单表单
//

import SwiftUI
import OSLog

struct EditListSheet: View {
    @ObservedObject var repository: TodoRepository
    let list: TodoList
    let folders: [TodoFolder]
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var color: String = "#007AFF"
    @State private var selectedFolderId: UUID? = nil
    @State private var isEphemeral: Bool = false
    @State private var showDismissAlert: Bool = false
    @State private var showArchiveConfirm: Bool = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "EditListSheet")

    // 预设颜色
    private let colors = [
        "#007AFF",  // 蓝色
        "#34C759",  // 绿色
        "#FF9500",  // 橙色
        "#FF3B30",  // 红色
        "#AF52DE",  // 紫色
        "#FF2D55",  // 粉色
        "#5856D6",  // 靛蓝
        "#00C7BE"   // 青色
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: HoloSpacing.lg) {
                    // 清单名称
                    VStack(alignment: .leading, spacing: 6) {
                        Text("清单名称")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        TextField("输入清单名称", text: $name)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.holoCardBackground)
                            .cornerRadius(HoloRadius.sm)
                    }

                    // 所属文件夹
                    VStack(alignment: .leading, spacing: 6) {
                        Text("所属文件夹")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        Menu {
                            ForEach(folders, id: \.id) { folder in
                                Button {
                                    selectedFolderId = folder.id
                                } label: {
                                    HStack {
                                        Text(folder.name)
                                        if selectedFolderId == folder.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "folder")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)

                                Text(selectedFolderName)
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()

                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.holoCardBackground)
                            .cornerRadius(HoloRadius.sm)
                        }
                    }

                    // 颜色选择
                    VStack(alignment: .leading, spacing: 6) {
                        Text("清单颜色")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        HStack(spacing: 8) {
                            ForEach(colors, id: \.self) { c in
                                Button {
                                    color = c
                                } label: {
                                    Circle()
                                        .fill(Color(hex: c))
                                        .frame(width: 32, height: 32)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: color == c ? 3 : 0)
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }

                    // 一次性清单开关（AI/事项建的清单默认开启，做完自动归档退场）
                    HStack(spacing: HoloSpacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("一次性清单")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)

                            Text("任务全部做完后自动归档，可随时在归档管理恢复")
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: $isEphemeral)
                            .labelsHidden()
                            .tint(.holoPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.holoCardBackground)
                    .cornerRadius(HoloRadius.sm)

                    // 归档清单（此前全 App 无归档清单入口，唯一出口只有删除）
                    Button {
                        showArchiveConfirm = true
                    } label: {
                        HStack(spacing: HoloSpacing.sm) {
                            Image(systemName: "archivebox")
                                .font(.system(size: 16, weight: .medium))

                            Text("归档这个清单")
                                .font(.holoBody)

                            Spacer()
                        }
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.holoCardBackground)
                        .cornerRadius(HoloRadius.sm)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
            }
            .navigationTitle("编辑清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        if name != list.name
                            || color != (list.color ?? "#007AFF")
                            || selectedFolderId != list.folder?.id
                            || isEphemeral != list.isEphemeral {
                            showDismissAlert = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveList()
                    }
                    .foregroundColor(name.trimmingCharacters(in: .whitespaces).isEmpty ? .holoTextSecondary : .holoPrimary)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = list.name
            color = list.color ?? "#007AFF"
            selectedFolderId = list.folder?.id
            isEphemeral = list.isEphemeral
        }
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.visible)
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
        .alert("归档清单", isPresented: $showArchiveConfirm) {
            Button("取消", role: .cancel) { }
            Button("归档") { archiveCurrentList() }
        } message: {
            Text("清单会从各入口收起，可在「归档管理」随时恢复；清单里未完成的任务仍会保留在任务列表中。")
        }
    }

    private var selectedFolderName: String {
        guard let folderId = selectedFolderId else {
            return String(localized: "未选择")
        }
        return folders.first(where: { $0.id == folderId })?.name ?? String(localized: "未选择")
    }

    private var selectedFolder: TodoFolder? {
        guard let folderId = selectedFolderId else { return nil }
        return folders.first(where: { $0.id == folderId })
    }

    private func saveList() {
        do {
            try repository.updateList(
                list,
                name: name.trimmingCharacters(in: .whitespaces),
                color: color,
                folder: selectedFolder,
                isEphemeral: isEphemeral,
                shouldUpdateFolder: true
            )
            dismiss()
        } catch {
            Self.logger.error("更新清单失败: \(error.localizedDescription)")
        }
    }

    private func archiveCurrentList() {
        do {
            try repository.archiveList(list)
            dismiss()
        } catch {
            Self.logger.error("归档清单失败: \(error.localizedDescription)")
        }
    }
}
