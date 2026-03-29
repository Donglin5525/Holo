//
//  TagInputView.swift
//  Holo
//
//  观点模块 - 标签输入
//  用于添加和管理想法标签
//

import SwiftUI

// MARK: - TagInputView

/// 标签输入视图
struct TagInputView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    @Binding var selectedTags: [String]

    /// 输入文本
    @State private var inputText: String = ""

    /// 推荐标签（基于使用频率）
    @State private var suggestedTags: [String] = []

    /// 所有标签
    @State private var allTags: [ThoughtTag] = []

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 输入栏
                inputBar

                Divider()
                    .padding(.vertical, HoloSpacing.sm)

                // 已选标签
                if !selectedTags.isEmpty {
                    selectedTagsSection
                }

                // 推荐标签
                if !suggestedTags.isEmpty {
                    suggestedTagsSection
                }

                Spacer()
            }
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.top, HoloSpacing.md)
            .background(Color.holoBackground)
            .navigationTitle("添加标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                loadTags()
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: HoloSpacing.sm) {
            TextField("输入标签名称...", text: $inputText)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .submitLabel(.done)
                .onSubmit {
                    addTag()
                }

            Button {
                addTag()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(inputText.isEmpty ? .holoTextSecondary : .holoPrimary)
            }
            .disabled(inputText.isEmpty)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    // MARK: - Selected Tags Section

    private var selectedTagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("已选标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(selectedTags, id: \.self) { tag in
                        SelectedTagChip(tag: tag) {
                            removeTag(tag)
                        }
                    }
                }
            }
        }
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - Suggested Tags Section

    private var suggestedTagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("推荐标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestedTags, id: \.self) { tag in
                        SuggestedTagChip(
                            tag: tag,
                            isSelected: selectedTags.contains(tag)
                        ) {
                            toggleTag(tag)
                        }
                    }
                }
            }
        }
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - Actions

    /// 加载标签
    private func loadTags() {
        // TODO: 从 Core Data 加载标签
        // 临时使用模拟数据
        suggestedTags = ["工作", "生活", "灵感", "学习", "阅读"]
    }

    /// 添加标签
    private func addTag() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !selectedTags.contains(trimmed) else {
            inputText = ""
            return
        }

        selectedTags.append(trimmed)
        inputText = ""
        HapticManager.light()
    }

    /// 切换标签选中状态
    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            selectedTags.append(tag)
        }
        HapticManager.light()
    }

    /// 移除标签
    private func removeTag(_ tag: String) {
        selectedTags.removeAll { $0 == tag }
        HapticManager.light()
    }
}

// MARK: - Selected Tag Chip

/// 已选标签芯片
struct SelectedTagChip: View {
    let tag: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .font(.holoCaption)
                .foregroundColor(.white)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.holoPrimary)
        .cornerRadius(HoloRadius.full)
    }
}

// MARK: - Suggested Tag Chip

/// 推荐标签芯片
struct SuggestedTagChip: View {
    let tag: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("#\(tag)")
                    .font(.holoCaption)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
            .cornerRadius(HoloRadius.full)
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.holoPrimary : Color.holoDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    TagInputView(selectedTags: .constant(["工作", "灵感"]))
}