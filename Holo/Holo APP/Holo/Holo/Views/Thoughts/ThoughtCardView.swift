//
//  ThoughtCardView.swift
//  Holo
//
//  观点模块 - 想法卡片组件
//  显示单条想法的预览信息
//

import SwiftUI
import CoreData

// MARK: - ThoughtCardView

/// 想法卡片视图
/// 设计参考：
/// - 白色背景，圆角 28pt
/// - 顶部：心情 + 日期
/// - 中间：内容预览（2-3 行）
/// - 底部：标签 + 引用数
struct ThoughtCardView: View {

    // MARK: - Properties

    let thought: Thought

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶部：心情 + 日期
            headerView

            // 中间：内容预览
            contentView

            // 底部：标签 + 引用信息
            footerView
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.holoCardBackground)
                .shadow(color: HoloShadow.card, radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - 顶部区域

    private var headerView: some View {
        HStack(spacing: 8) {
            // 心情图标
            if let moodType = thought.moodType {
                Text(moodType.emoji)
                    .font(.system(size: 20))
            } else {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
            }

            // 日期
            Text(thought.formattedDate)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            // 更多操作按钮
            Button {
                // TODO: 显示操作菜单
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    // MARK: - 内容区域

    private var contentView: some View {
        Text(thought.previewText)
            .font(.holoBody)
            .foregroundColor(.holoTextPrimary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部区域

    private var footerView: some View {
        HStack(spacing: 0) {
            // 标签
            let tags = thought.tagArray
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags.prefix(3)) { tag in
                            tagChip(tag)
                        }
                        if tags.count > 3 {
                            Text("+\(tags.count - 3)")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
                        }
                    }
                }
            }

            Spacer()

            // 引用信息
            let refCount = thought.referenceCount + thought.referencedByCount
            if refCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                    Text("\(refCount)")
                        .font(.holoLabel)
                }
                .foregroundColor(.holoPurple)
            }
        }
    }

    // MARK: - 标签 Chip

    private func tagChip(_ tag: ThoughtTag) -> some View {
        Text("#\(tag.name)")
            .font(.holoLabel)
            .foregroundColor(tag.tagColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tag.tagColor.opacity(0.1))
            .cornerRadius(HoloRadius.sm)
    }
}

// MARK: - Preview

#Preview("想法卡片") {
    VStack(spacing: 16) {
        Text("预览需要 Core Data context")
            .font(.holoBody)
            .foregroundColor(.holoTextSecondary)
    }
    .padding()
    .background(Color.holoBackground)
}