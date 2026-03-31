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
    @State private var showDismissAlert: Bool = false

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
                            || selectedFolderId != list.folder?.id {
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
        }
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
    }

    private var selectedFolderName: String {
        guard let folderId = selectedFolderId else {
            return "未选择"
        }
        return folders.first(where: { $0.id == folderId })?.name ?? "未选择"
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
                shouldUpdateFolder: true
            )
            dismiss()
        } catch {
            Self.logger.error("更新清单失败: \(error.localizedDescription)")
        }
    }
}
