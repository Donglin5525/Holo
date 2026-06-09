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
    var onNavigate: (() -> Void)?

    // MARK: - Body

    var body: some View {
        Button(action: { onNavigate?() }) {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部：心情 + 日期
                headerView

                // 中间：内容预览
                contentView

                // 底部：标签 + 引用信息
                footerView
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoCardBackground)
                    .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
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

            // 更多操作按钮（使用 onTapGesture 避免与外层导航 Button 冲突）
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundColor(.holoTextSecondary)
                .onTapGesture {
                    // TODO: 显示操作菜单
                }
        }
    }

    // MARK: - 内容区域

    private var contentView: some View {
        ExpandableText(
            text: thought.plainContent,
            lineLimit: 7
        )
    }

    // MARK: - 底部区域

    private var footerView: some View {
        HStack(spacing: 0) {
            // 标签展示策略：
            // 1. 有手动标签 → 展示手动标签（不变）
            // 2. 无手动标签 + 有 AI 标签 → 展示 1-2 个 AI 标签（灰色调）
            // 3. 正在整理 → 展示"AI 正在整理..."
            let tags = thought.tagArray
            let aiTagNames = thought.visibleAITagNames

            if !tags.isEmpty {
                // 有手动标签：展示手动标签
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
            } else if !aiTagNames.isEmpty {
                // 无手动标签，有 AI 标签：灰色调展示
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(aiTagNames.prefix(2), id: \.self) { tagName in
                            aiTagChip(tagName)
                        }
                    }
                }
            } else if thought.organizedStatus == "processing" {
                // 正在整理
                Text("AI 正在整理...")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
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
                .foregroundColor(.holoPrimary)
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

    // MARK: - AI 标签 Chip（灰色调 + AI 角标）

    private func aiTagChip(_ tagName: String) -> some View {
        HStack(spacing: 3) {
            Text("#\(tagName)")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Text("AI")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.holoTextSecondary.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.holoTextSecondary.opacity(0.08))
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