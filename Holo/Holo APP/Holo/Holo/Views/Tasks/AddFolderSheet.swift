//
//  AddFolderSheet.swift
//  Holo
//
//  添加文件夹表单
//  统一全局风格：圆角卡片、自定义样式
//

import SwiftUI
import OSLog

struct AddFolderSheet: View {
    @ObservedObject var repository: TodoRepository
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var showDismissAlert: Bool = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "AddFolderSheet")

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
            .navigationTitle("新建文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                            showDismissAlert = true
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("创建") {
                        createFolder()
                    }
                    .foregroundColor(name.trimmingCharacters(in: .whitespaces).isEmpty ? .holoTextSecondary : .holoPrimary)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
        }
    }

    private func createFolder() {
        do {
            _ = try repository.createFolder(name: name.trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            Self.logger.error("创建文件夹失败: \(error.localizedDescription)")
        }
    }
}

#Preview {
    AddFolderSheet(repository: TodoRepository.shared)
}
