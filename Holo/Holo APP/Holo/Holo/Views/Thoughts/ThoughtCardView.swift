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
/// - 顶部：日期 + 状态
/// - 中间：内容预览（2-3 行）
/// - 底部：标签 + 引用数
struct ThoughtCardView: View {

    // MARK: - Properties

    let thought: Thought
    var onNavigate: (() -> Void)?
    var onTagTap: ((String) -> Void)?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶部：日期 + 状态
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
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .onTapGesture {
            onNavigate?()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onNavigate?()
        }
    }

    // MARK: - 顶部区域

    private var headerView: some View {
        HStack(spacing: 8) {
            // 日期
            Text(thought.formattedDate)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            statusBadge

            // 更多操作按钮（使用 onTapGesture 避免与外层导航 Button 冲突）
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundColor(.holoTextSecondary)
                .onTapGesture {
                    // TODO: 显示操作菜单
                }
        }
    }

    private var statusBadge: some View {
        let status = organizationDisplayStatus
        return HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(status.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(status.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.1))
        .clipShape(Capsule())
    }

    private var organizationDisplayStatus: (title: String, icon: String, color: Color) {
        if thought.hasActiveTopic {
            return ("已入主题", "folder.fill", .holoSuccess)
        }
        if thought.organizedStatus == "processing" || thought.organizedStatus == "pending" {
            return ("整理中", "sparkles", .holoPrimary)
        }
        if thought.organizedStatus == "failed" {
            return ("整理失败", "exclamationmark.circle.fill", .holoError)
        }
        if !thought.visibleAITagNames.isEmpty || thought.organizedStatus == "organized" {
            return ("已整理", "checkmark.seal.fill", .holoPrimary)
        }
        return ("待整理", "circle.dotted", .holoTextSecondary)
    }

    // MARK: - 内容区域

    private var contentView: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ExpandableText(
                text: thought.plainContent,
                lineLimit: 7
            )

            if !thought.sortedAttachments.isEmpty {
                inlineAttachmentsView
            }
        }
    }

    // MARK: - 底部区域

    private var footerView: some View {
        HStack(spacing: 0) {
            let tags = thought.tagArray
            let aiTagNames = thought.visibleAITagNames
            let presentation = ThoughtTagPresentation.card(
                manualNames: tags.map(\.name),
                aiNames: aiTagNames
            )

            if !presentation.isEmpty {
                // 用户标签与 AI 标签同时展示，同名标签只展示一次。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(presentation.manualNames, id: \.self) { tagName in
                            if let tag = tags.first(where: {
                                ThoughtTagNormalizer.key($0.name) == ThoughtTagNormalizer.key(tagName)
                            }) {
                                tagChip(tag)
                            }
                        }
                        ForEach(presentation.aiNames, id: \.self) { tagName in
                            aiTagChip(tagName)
                        }
                        if presentation.hiddenCount > 0 {
                            Text("+\(presentation.hiddenCount)")
                                .font(.holoLabel)
                                .foregroundColor(.holoTextSecondary)
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

    private var inlineAttachmentsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoloSpacing.sm) {
                ForEach(Array(thought.sortedAttachments.enumerated()), id: \.element.id) { _, attachment in
                    ThoughtAttachmentThumbnailView(
                        thumbnailData: attachment.thumbnailData,
                        fileName: attachment.thumbnailFileName,
                        thoughtId: thought.id
                    )
                    .frame(width: 80, height: 80)
                }
            }
        }
    }

    // MARK: - 标签 Chip

    private func tagChip(_ tag: ThoughtTag) -> some View {
        Button {
            onTagTap?(tag.name)
        } label: {
            Text("#\(tag.name)")
                .font(.holoLabel)
                .foregroundColor(tag.tagColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tag.tagColor.opacity(0.1))
                .cornerRadius(HoloRadius.sm)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("按标签 \(tag.name) 筛选")
    }

    // MARK: - AI 标签 Chip（灰色调 + AI 角标）

    private func aiTagChip(_ tagName: String) -> some View {
        Button {
            onTagTap?(tagName)
        } label: {
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
        .buttonStyle(.plain)
        .accessibilityLabel("按 AI 标签 \(tagName) 筛选")
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
