//
//  ColorPickerPopover.swift
//  Holo
//
//  观点模块 - 颜色选择弹窗
//  预设设计系统颜色，选择后插入颜色 Markdown 语法
//

import SwiftUI

// MARK: - 预设颜色

/// 预设颜色选项
private struct PresetColor: Identifiable {
    let id = UUID()
    let name: String
    let hex: String
    let color: Color
}

/// 预设颜色列表（复用 DesignSystem 颜色）
private let presetColors: [PresetColor] = [
    PresetColor(name: "橙", hex: "#F46D38", color: .holoPrimary),
    PresetColor(name: "蓝", hex: "#60A5FA", color: .holoInfo),
    PresetColor(name: "绿", hex: "#22C55E", color: .holoSuccess),
    PresetColor(name: "红", hex: "#EF4444", color: .holoError),
    PresetColor(name: "紫", hex: "#C084FC", color: .holoPurple),
    PresetColor(name: "粉", hex: "#EC4899", color: .holoChart4),
    PresetColor(name: "青", hex: "#10B981", color: .holoChart5),
    PresetColor(name: "靛", hex: "#8B5CF6", color: .holoChart3),
]

// MARK: - ColorPickerPopover

/// 颜色选择弹窗视图
struct ColorPickerPopover: View {

    @Binding var content: String
    @Binding var selectedRange: NSRange
    @Environment(\.dismiss) private var dismiss

    /// 临时选中范围（用于在 sheet 中保持正确的范围）
    @State private var savedRange: NSRange = NSRange(location: 0, length: 0)

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                Text("选择文字颜色")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.lg)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.md), count: 4), spacing: HoloSpacing.md) {
                    ForEach(presetColors) { preset in
                        colorButton(preset)
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)

                // 自定义颜色输入
                customColorSection

                Spacer()
            }
            .padding(.top, HoloSpacing.md)
            .background(Color.holoBackground)
            .navigationTitle("颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .onAppear {
            savedRange = selectedRange
        }
    }

    // MARK: - 颜色按钮

    private func colorButton(_ preset: PresetColor) -> some View {
        Button {
            insertColorTag(hex: preset.hex)
            dismiss()
        } label: {
            VStack(spacing: HoloSpacing.xs) {
                Circle()
                    .fill(preset.color)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )

                Text(preset.name)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    // MARK: - 自定义颜色

    private var customColorSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("自定义")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.sm) {
                TextField("#RRGGBB", text: $customHexInput)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .padding(HoloSpacing.sm)
                    .background(Color.holoCardBackground)
                    .cornerRadius(HoloRadius.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )

                Button("应用") {
                    let hex = customHexInput.hasPrefix("#") ? customHexInput : "#\(customHexInput)"
                    insertColorTag(hex: hex)
                    dismiss()
                }
                .font(.holoLabel)
                .foregroundColor(.holoPrimary)
                .disabled(customHexInput.count < 4)
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
    }

    @State private var customHexInput: String = ""

    // MARK: - 插入颜色标记

    /// 在内容中插入 {color:#hex}选中文本{/color}
    private func insertColorTag(hex: String) {
        MarkdownTextView.insertFormat(
            prefix: "{color:\(hex)}",
            suffix: "{/color}",
            content: $content,
            range: $selectedRange
        )
    }
}
