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

    private let thoughtRepository = ThoughtRepository()

    /// 输入文本
    @State private var inputText: String = ""

    /// 用户认可标签（手动 / 正文提取 / 已确认 AI 来源）
    @State private var userTags: [String] = []

    /// AI 分类标签（纯 AI 来源、尚未被用户认可）
    @State private var aiTags: [String] = []

    /// 首次使用时的默认标签
    private static let defaultTags = ["工作", "生活", "灵感", "学习", "阅读"]

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 输入栏
                inputBar

                Divider()
                    .padding(.vertical, HoloSpacing.sm)

                // 标签区（纵向滚动，换行后内容增多也不溢出）
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        if !selectedTags.isEmpty {
                            selectedTagsSection
                        }
                        if !userTags.isEmpty {
                            userTagsSection
                        }
                        if !aiTags.isEmpty {
                            aiTagsSection
                        }
                    }
                    .padding(.top, HoloSpacing.sm)
                    .padding(.bottom, HoloSpacing.lg)
                }
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

    // MARK: - User Tags Section（用户认可标签，优先展示）

    private var userTagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("我的标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            FlowLayout(spacing: 8) {
                ForEach(userTags, id: \.self) { tag in
                    SuggestedTagChip(
                        tag: tag,
                        isAI: false,
                        isSelected: selectedTags.contains(tag)
                    ) {
                        toggleTag(tag)
                    }
                }
            }
        }
    }

    // MARK: - AI Tags Section（AI 分类标签，换行展示 + 明确标识）

    private var aiTagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.holoAI)
                Text("AI 分类标签")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            FlowLayout(spacing: 8) {
                ForEach(aiTags, id: \.self) { tag in
                    SuggestedTagChip(
                        tag: tag,
                        isAI: true,
                        isSelected: selectedTags.contains(tag)
                    ) {
                        toggleTag(tag)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// 加载标签：用户认可组优先，AI 分类组其次
    private func loadTags() {
        // 用户认可标签；首次使用（无任何认可标签）时用默认标签兜底引导
        var recognized = thoughtRepository.fetchUserRecognizedTagNames(limit: 60)
        if recognized.isEmpty {
            recognized = Self.defaultTags
        }
        let ai = thoughtRepository.fetchUnrecognizedAITagNames(limit: 40)

        userTags = recognized.filter { !selectedTags.contains($0) }
        aiTags = ai.filter { !selectedTags.contains($0) }
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

/// 推荐标签芯片（isAI = true 时显示 ✨ 标识与 AI 配色，明确来源）
struct SuggestedTagChip: View {
    let tag: String
    let isAI: Bool
    let isSelected: Bool
    let action: () -> Void

    /// 强调色：AI 标签用 holoAI，用户标签用 holoPrimary
    private var accentColor: Color { isAI ? .holoAI : .holoPrimary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isAI {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(accentColor.opacity(0.85))
                }
                Text("#\(tag)")
                    .font(.holoCaption)
                    .foregroundColor(isSelected ? accentColor : .holoTextSecondary)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(chipBackground)
            .cornerRadius(HoloRadius.full)
            .overlay(
                Capsule()
                    .stroke(isSelected ? accentColor : Color.holoDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 芯片背景：选中加深，未选 AI 标签带淡紫底色与用户标签区分
    private var chipBackground: Color {
        if isSelected {
            return accentColor.opacity(isAI ? 0.12 : 0.1)
        }
        return isAI ? accentColor.opacity(0.06) : Color.holoCardBackground
    }
}

// MARK: - Preview

#Preview {
    TagInputView(selectedTags: .constant(["工作", "灵感"]))
}
