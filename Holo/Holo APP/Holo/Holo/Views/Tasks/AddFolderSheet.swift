//
//  AddFolderSheet.swift
//  Holo
//
//  添加文件夹表单
//

import SwiftUI
import OSLog

struct AddFolderSheet: View {
    @ObservedObject var repository: TodoRepository
    @Environment(\.dismiss) var dismiss
    @State private var name = ""

    private static let logger = Logger(subsystem: "com.holo.app", category: "AddFolderSheet")

    var body: some View {
        NavigationStack {
            Form {
                Section("文件夹信息") {
                    TextField("文件夹名称", text: $name)
                        .autocapitalization(.words)
                }
            }
            .navigationTitle("新建文件夹")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        createFolder()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
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
