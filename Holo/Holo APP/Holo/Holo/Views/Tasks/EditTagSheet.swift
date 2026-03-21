//
//  EditTagSheet.swift
//  Holo
//
//  编辑标签表单
//

import SwiftUI
import OSLog

struct EditTagSheet: View {
    @ObservedObject var repository: TodoRepository
    let tag: TodoTag
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var color: String = "#4A90D9"

    private static let logger = Logger(subsystem: "com.holo.app", category: "EditTagSheet")

    // 预设颜色
    private let colors = [
        "#4A90D9",  // 蓝色
        "#E74C3C",  // 红色
        "#2ECC71",  // 绿色
        "#F39C12",  // 橙色
        "#9B59B6",  // 紫色
        "#1ABC9C",  // 青色
        "#FF2D55",  // 粉色
        "#5856D6"   // 靛蓝
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                VStack(spacing: HoloSpacing.lg) {
                    // 标签名称
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标签名称")
                            .font(.holoLabel)
                            .foregroundColor(.holoTextSecondary)

                        TextField("输入标签名称", text: $name)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.holoCardBackground)
                            .cornerRadius(HoloRadius.sm)
                    }

                    // 颜色选择
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标签颜色")
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
            .navigationTitle("编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveTag()
                    }
                    .foregroundColor(name.trimmingCharacters(in: .whitespaces).isEmpty ? .holoTextSecondary : .holoPrimary)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = tag.name
            color = tag.color
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private func saveTag() {
        do {
            try repository.updateTag(tag, name: name.trimmingCharacters(in: .whitespaces), color: color)
            dismiss()
        } catch {
            Self.logger.error("更新标签失败: \(error.localizedDescription)")
        }
    }
}
