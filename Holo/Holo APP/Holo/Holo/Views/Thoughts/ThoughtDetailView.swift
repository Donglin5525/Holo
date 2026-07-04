//
//  ThoughtDetailView.swift
//  Holo
//
//  观点模块 - 想法详情页
//  展示想法完整内容、引用关系和反向链接
//

import SwiftUI
import CoreData
import os.log

// MARK: - ThoughtDetailView

/// 想法详情视图
struct ThoughtDetailView: View {

    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtDetailView")

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    let thoughtId: UUID
    let thoughtRepository: ThoughtRepository

    /// 当前想法
    @State private var thought: Thought? = nil

    /// 该想法引用的其他想法
    @State private var references: [Thought] = []

    /// 引用该想法的其他想法
    @State private var referencedBy: [Thought] = []

    /// 选中的引用想法 ID（用于跳转）
    @State private var selectedReferenceId: UUID? = nil

    /// 是否显示编辑 sheet
    @State private var showEditSheet: Bool = false

    /// 是否显示全屏图片浏览
    @State private var showAttachmentGallery: Bool = false
    @State private var galleryStartIndex: Int = 0

    /// AI 标签分配
    @State private var aiAssignments: [ThoughtTagAssignment] = []

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    // 内容区域
                    contentSection

                    // 标签区域
                    if let thought = thought, !thought.tagArray.isEmpty {
                        tagsSection
                    }

                    // AI 归类区域
                    if !aiAssignments.isEmpty {
                        aiTagsSection
                    }

                    // 引用区域（该想法引用的其他想法）
                    if !references.isEmpty {
                        referencesSection
                    }

                    // 反向链接区域（引用该想法的其他想法）
                    if !referencedBy.isEmpty {
                        referencedBySection
                    }

                    // 底部间距
                    Spacer(minLength: HoloSpacing.xxl)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("想法详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("编辑") {
                        showEditSheet = true
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .sheet(item: $selectedReferenceId) { refId in
                ThoughtDetailSheetView(
                    thoughtId: refId,
                    thoughtRepository: thoughtRepository
                )
            }
            .sheet(isPresented: $showEditSheet) {
                ThoughtEditorView(
                    onSave: {
                        loadData()
                    },
                    editingThoughtId: thoughtId
                )
            }
            .fullScreenCover(isPresented: $showAttachmentGallery) {
                if let thought = thought {
                    ThoughtGalleryView(
                        attachments: thought.sortedAttachments,
                        startIndex: galleryStartIndex
                    )
                }
            }
            .onAppear {
                loadData()
            }
        }
    }

    // MARK: - 数据加载

    private func loadData() {
        do {
            thought = try thoughtRepository.fetchById(thoughtId)
            references = try thoughtRepository.getReferences(for: thoughtId)
            referencedBy = try thoughtRepository.getReferencedBy(id: thoughtId)
            aiAssignments = (try? thoughtRepository.fetchVisibleAIAssignments(thoughtId: thoughtId)) ?? []
        } catch {
            logger.error("加载数据失败：\(error)")
        }
    }

    // MARK: - 内容区域

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 日期
            HStack {
                Spacer()

                Text(thought?.formattedDate ?? "")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 内容（Markdown 渲染）
            if let content = thought?.content, !content.isEmpty {
                MarkdownRenderer.render(content)
                    .multilineTextAlignment(.leading)
            } else {
                Text("")
                    .font(.holoBody)
            }

            if let thought = thought, !thought.sortedAttachments.isEmpty {
                inlineAttachmentsSection
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - 图片附件区域

    private var inlineAttachmentsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HoloSpacing.sm) {
                    if let attachments = thought?.sortedAttachments {
                        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                            ThoughtAttachmentThumbnailView(
                                thumbnailData: attachment.thumbnailData,
                                fileName: attachment.thumbnailFileName,
                                thoughtId: thoughtId
                            )
                            .frame(width: 80, height: 80)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                galleryStartIndex = index
                                showAttachmentGallery = true
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 标签区域

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            FlowLayout(spacing: HoloSpacing.sm) {
                ForEach(thought?.tagArray ?? []) { tag in
                    TagChip(
                        text: "#\(tag.name)",
                        isSelected: true,
                        color: tag.tagColor
                    ) {
                        // 无操作
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - AI 归类区域

    private var aiTagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("AI 归类")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.holoTextSecondary)
            }

            FlowLayout(spacing: HoloSpacing.sm) {
                ForEach(aiAssignments, id: \.id) { assignment in
                    aiTagChip(assignment)
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - AI 标签 Chip（带操作按钮）

    private func aiTagChip(_ assignment: ThoughtTagAssignment) -> some View {
        let tagName = assignment.tag?.name ?? ""
        let isConfirmed = assignment.source == ThoughtTagAssignment.Source.confirmedAI.rawValue

        return HStack(spacing: 4) {
            Text("#\(tagName)")
                .font(.holoLabel)
                .foregroundColor(isConfirmed ? .holoPrimary : .holoTextSecondary)

            // AI 角标
            Text("AI")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(isConfirmed ? .holoPrimary.opacity(0.6) : .holoTextSecondary.opacity(0.5))

            // 确认按钮（保留 AI 标签）
            if !isConfirmed {
                Button {
                    let service = ThoughtOrganizationService()
                    service.confirmAssignment(assignmentId: assignment.id)
                    loadData()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                }

                // 拒绝按钮（删除 AI 标签）
                Button {
                    guard let tagName = assignment.tag?.name else { return }
                    let service = ThoughtOrganizationService()
                    service.rejectAndRecord(assignmentId: assignment.id, tagName: tagName)
                    loadData()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.red.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isConfirmed
                ? Color.holoPrimary.opacity(0.08)
                : Color.holoTextSecondary.opacity(0.06)
        )
        .cornerRadius(HoloRadius.sm)
    }

    // MARK: - 引用区域

    private var referencesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("引用")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: HoloSpacing.sm) {
                ForEach(references) { ref in
                    ReferenceCardView(thought: ref)
                        .onTapGesture {
                            selectedReferenceId = ref.id
                        }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    // MARK: - 反向链接区域

    private var referencedBySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("被引用")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "link.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.holoPrimary)
            }

            VStack(spacing: HoloSpacing.sm) {
                ForEach(referencedBy) { ref in
                    ReferenceCardView(thought: ref)
                        .onTapGesture {
                            selectedReferenceId = ref.id
                        }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }
}

private struct ThoughtDetailSheetView: View {
    let thoughtId: UUID
    let thoughtRepository: ThoughtRepository

    var body: some View {
        ThoughtDetailView(
            thoughtId: thoughtId,
            thoughtRepository: thoughtRepository
        )
    }
}

// MARK: - ReferenceCardView

/// 引用卡片组件
struct ReferenceCardView: View {
    let thought: Thought

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部：日期
            HStack {
                Text(thought.formattedDate)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
            }

            // 内容预览
            Text(thought.previewText)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(2)

            // 标签
            if !thought.tagArray.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(thought.tagArray.prefix(3)) { tag in
                        Text("#\(tag.name)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(tag.tagColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tag.tagColor.opacity(0.1))
                            .cornerRadius(HoloRadius.sm)
                    }
                }
            }
        }
        .padding(HoloSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    // 需要 Core Data 环境
    Text("ThoughtDetailView Preview")
}
