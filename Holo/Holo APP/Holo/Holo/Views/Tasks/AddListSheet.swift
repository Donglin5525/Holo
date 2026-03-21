//
//  AddListSheet.swift
//  Holo
//
//  添加清单表单
//

import SwiftUI
import OSLog

struct AddListSheet: View {
    @ObservedObject var repository: TodoRepository
    let folder: TodoFolder?
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var color: String = "#007AFF"

    private static let logger = Logger(subsystem: "com.holo.app", category: "AddListSheet")

    var body: some View {
        NavigationStack {
            Form {
                Section("清单信息") {
                    TextField("清单名称", text: $name)
                        .autocapitalization(.words)

                    Picker("颜色", selection: $color) {
                        Label("蓝色", systemImage: "circle.fill")
                            .tag("#007AFF")
                        Label("绿色", systemImage: "circle.fill")
                            .tag("#34C759")
                        Label("橙色", systemImage: "circle.fill")
                            .tag("#FF9500")
                        Label("红色", systemImage: "circle.fill")
                            .tag("#FF3B30")
                        Label("紫色", systemImage: "circle.fill")
                            .tag("#AF52DE")
                    }
                }

                if let folder = folder {
                    Section("所属文件夹") {
                        Text(folder.name)
                    }
                }
            }
            .navigationTitle("新建清单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        createList()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func createList() {
        do {
            _ = try repository.createList(
                name: name.trimmingCharacters(in: .whitespaces),
                folder: folder,
                color: color
            )
            dismiss()
        } catch {
            Self.logger.error("创建清单失败: \(error.localizedDescription)")
        }
    }
}

#Preview {
    AddListSheet(repository: TodoRepository.shared, folder: nil)
}
