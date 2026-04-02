//
//  TagAutocompleteView.swift
//  Holo
//
//  观点模块 - 标签自动补全视图
//  当用户输入 # 时显示浮动建议列表
//

import SwiftUI

// MARK: - TagAutocompleteView

/// 标签自动补全建议列表
struct TagAutocompleteView: View {

    /// 当前输入的部分标签名（不含 #）
    let partialTag: String

    /// 从数据库获取的所有已有标签
    let allTags: [ThoughtTag]

    /// 选择标签后的回调
    let onSelect: (String) -> Void

    /// 筛选后的匹配标签
    private var matchedTags: [ThoughtTag] {
        if partialTag.isEmpty {
            return Array(allTags.prefix(5))
        }
        return allTags.filter { tag in
            tag.name.localizedCaseInsensitiveContains(partialTag)
        }
    }

    var body: some View {
        if !matchedTags.isEmpty {
            VStack(spacing: 0) {
                ForEach(matchedTags.prefix(5)) { tag in
                    tagRow(tag)
                }
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        }
    }

    // MARK: - 标签行

    private func tagRow(_ tag: ThoughtTag) -> some View {
        Button {
            HapticManager.light()
            onSelect(tag.name)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Text("#\(tag.name)")
                    .font(.holoLabel)
                    .foregroundColor(tag.tagColor)

                Spacer()

                if tag.usageCount > 0 {
                    Text("\(tag.usageCount)次")
                        .font(.system(size: 10))
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .contentShape(Rectangle())
        }
    }
}
