//
//  AddListSheet.swift
//  Holo
//
//  添加清单表单
//  统一全局风格：圆角卡片、自定义样式
//

import SwiftUI
import OSLog

struct AddListSheet: View {
    @ObservedObject var repository: TodoRepository
    let folder: TodoFolder?
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var color: String = "#007AFF"
    @State private var showDismissAlert: Bool = false

    private static let logger = Logger(subsystem: "com.holo.app", category: "AddListSheet")

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
                    if let folder = folder {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("所属文件夹")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)

                            HStack(spacing: HoloSpacing.sm) {
                                Image(systemName: "folder")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.holoTextSecondary)

                                Text(folder.name)
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)

                                Spacer()
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
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: c))
                                            .frame(width: 32, height: 32)

                                        // 选中指示
                                        if color == c {
                                            Circle()
                                                .strokeBorder(Color.white, lineWidth: 3)
                                                .frame(width: 32, height: 32)

                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
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
            .navigationTitle("新建清单")
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
                        createList()
                    }
                    .foregroundColor(name.trimmingCharacters(in: .whitespaces).isEmpty ? .holoTextSecondary : .holoPrimary)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .unsavedChangesAlert(isPresented: $showDismissAlert) {
            dismiss()
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
