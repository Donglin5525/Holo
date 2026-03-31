//
//  EditFolderSheet.swift
//  Holo
//
//  编辑文件夹表单
//

import SwiftUI
import OSLog

struct EditFolderSheet: View {
    @ObservedObject var repository: TodoRepository
    let folder: TodoFolder
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var showDismissAlert: Bool = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "EditFolderSheet")

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: HoloSpacing.lg) {
                    // 文件夹名称
                    VStack(alignment: .leading, spacing: 6) {
                        Text("文件夹名称")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        TextField("输入文件夹名称", text: $name)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.holoCardBackground)
                            .cornerRadius(HoloRadius.sm)
                    }

                    Spacer()
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
            }
            .navigationTitle("编辑文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        if name != folder.name {
                            showDismissAlert = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveFolder()
                    }
                    .foregroundColor(name.trimmingCharacters(in: .whitespaces).isEmpty ? .holoTextSecondary : .holoPrimary)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = folder.name
        }
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
    }

    private func saveFolder() {
        do {
            try repository.updateFolder(folder, name: name.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            Self.logger.error("更新文件夹失败: \(error.localizedDescription)")
        }
    }
}
